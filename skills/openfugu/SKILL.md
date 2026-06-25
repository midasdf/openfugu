---
name: openfugu
description: "Route coding tasks to Claude Code, Codex, or Antigravity based on task kind, agent capabilities, and prior success/failure ledger. Use openfugu when you need to pick the right subscription CLI agent for a coding task, inspect routing decisions cheaply, or run a task through the candidate worktree + verification pipeline. Triggers: 'openfugu', 'route task to agent', 'pick agent for task', 'claude vs codex', 'which agent should handle', 'routing'."
---

# openfugu - Subscription Coding Agent Router

openfugu routes a coding task to the best available subscription CLI
(Claude Code, Codex, or Antigravity) using a deterministic classifier,
agent capability checks, and a local success/failure ledger. It never
calls vendor model APIs directly and never reads API keys.

## When to use this skill

Use openfugu when:

- You have a concrete coding task and want it routed to the right agent
  instead of guessing or hard-coding a choice.
- You want to inspect the routing decision cheaply (no quota consumed)
  before committing to a real run.
- You want a candidate worktree + objective verification pipeline so
  a bad candidate is rejected before touching the working tree.

Do NOT use openfugu for:

- Pure research or chat (no file changes expected). Just answer.
- Tasks that require direct vendor model API calls. openfugu only
  drives official local CLIs via argv.
- Environments where none of the three subscription CLIs are installed
  and authenticated. Run `openfugu doctor` first to check.

## Recommended flow for coding agents

1. **Health check (cheap, no quota):**
   ```
   openfugu doctor
   openfugu list-agents
   ```
   `doctor` reports config/git/worktree status plus per-agent
   compatibility, auth, and runnability. `list-agents` is the terse
   alias. Only proceed when at least one agent is `runnable=true`.

2. **Inspect routing (cheap, no quota):**
   ```
   openfugu route "your task description"
   ```
   Prints the router name, classified route, preferred agent, per-agent
   scores (including ledger reputation), and the selected agent. This
   is the recommended pre-flight check before spending subscription
   quota.

3. **Dry run (no apply, candidate worktree only):**
   ```
   openfugu run --no-apply "your task description"
   ```
   Routes, runs the selected agent in an isolated worktree, verifies,
   and reports without applying the patch to the working tree.

4. **Real run (apply + reverify):**
   ```
   openfugu run "your task description"
   ```
   Routes, runs, verifies in the candidate worktree, applies the
   accepted commit with `cherry-pick --no-commit`, and re-runs the
   same verification on the real working tree.

## Async job CLI

For fire-and-forget tasks, openfugu provides a daemon-less async
flow. Job state is a single JSON file per job under
`.openfugu/jobs/<id>.json`, so polling is a stateless file read.

```
openfugu submit "your task"     # returns immediately with job_id
openfugu poll <job-id>          # check status without blocking
openfugu wait <job-id>          # block until the job finishes
openfugu jobs                   # list all known job ids and statuses
```

Status values: `queued`, `running`, `ok`, `failed`, `canceled`.
`wait` exits with the job's exit code when known, so it composes
with shell scripts.

## NDJSON streaming

`openfugu run --json "task"` and `openfugu route --json "task"` emit
line-delimited JSON events so a parent process can consume routing
and execution progress programmatically:

```jsonl
{"event":"route_start","task":"..."}
{"event":"route_decision","router":"heuristic","route":"test_fix","selected":"claude","score":125}
{"event":"agent_start","agent":"claude"}
{"event":"agent_done","agent":"claude","accepted":true,"applied":true,"reverified":true}
{"event":"result","code":0,"agent":"claude","accepted":true,"applied":true,"reverified":true}
```

Event types: `route_start`, `route_decision`, `agent_start`,
`agent_done`, `result`, `error`.

## Flag forms

Both `--flag value` and `--flag=value` are accepted everywhere. Coding
agents that want to avoid shell-quoting ambiguity should prefer the
inline `=` form:

```
openfugu run --planner=capability --agents=codex "fix the flaky test"
```

## Planners

`--planner` selects the routing backend:

- `subscription-agent` (default): asks a structured-output subscription
  CLI for a JSON routing hint, validates it, and folds it into local
  scoring. Falls back to heuristic on invalid output.
- `heuristic`: pure local keyword + capability scoring. No subscription
  quota consumed for routing. Use this when you want deterministic,
  offline routing.
- `capability`: deterministic planner that emits plan nodes with
  explicit capability queries (edit_files, run_commands,
  structured_output) so the scheduler skips structurally-ineligible
  agents at selection time rather than failing at run time.

## Exit codes

| Code | Meaning | What to do |
|------|---------|------------|
| 0    | ok | task accepted and (if not --no-apply) applied + reverified |
| 2    | usage error | check flags; run `openfugu --help` |
| 3    | no subscription-compatible agent available | run `openfugu doctor`; ensure a CLI is installed, supported, and subscription-authenticated |
| 4    | budget exhausted | retry later or raise budget |
| 5    | verification failed | inspect candidate output; the agent ran but the result did not pass `zig build`/`zig build test` or configured verify commands |
| 6    | workspace error | check git worktree setup; run `openfugu doctor` |
| 7    | planner error | retry with `--planner heuristic` |
| 8    | compatibility error | agent version unsupported; run `openfugu doctor` |
| 130  | canceled (SIGINT) | re-run if intentional |

## Task kind vocabulary

The classifier recognises these kinds (matched by English and Japanese
keywords, case-insensitive, priority-ordered):

`general`, `bugfix`, `test_fix`, `refactor`, `terminal`, `review`,
`frontend`, `broad`.

The router hint JSON must use the same vocabulary for `task_kind`.

## Agent aliases

`--agents` accepts: `claude`, `claudecode`, `claude-code`, `codex`,
`agy`, `antigravity`. `auto` (in the TUI) clears the filter.

## Interactive TUI

Running `openfugu` without arguments starts a fullscreen TUI. Type a
task to route and execute it. `:help` inside the TUI lists all commands.
`:` commands cover git, CI, file viewing, planner/agent/mode
switching, history, and task replay. Unknown commands show a "did you
mean" suggestion.

## Ledger and reputation

openfugu records each run in `.openfugu/ledger.jsonl`. Content is off
by default (only a hash is stored). Scores incorporate prior
success/failure counts: a high success rate raises the score; chronic
failure lowers it. `openfugu usage` and `openfugu status` summarise
the ledger.

## Boundaries

- openfugu is architecture-inspired by Sakana AI's Fugu Ultra. It is
  not a reproduction of trained coordinators or private routers.
- openfugu does not read OAuth stores, cookies, keychains, or vendor
  session files. It invokes official local CLI binaries through argv
  arrays.
- Git worktrees isolate candidate changes but are not a security
  sandbox.
- The default policy is subscription-only. API-key, unauthenticated,
  and unknown auth are rejected unless an explicit policy says
  otherwise.

## MCP server mode

openfugu speaks MCP (Model Context Protocol) over stdio so coding
agents can call it as a local MCP server without spawning the CLI:

```jsonc
"mcp": {
  "openfugu": {
    "type": "local",
    "command": ["/home/USER/.local/bin/openfugu", "mcp"],
    "enabled": true
  }
}
```

Exposed tools: `route`, `run`, `submit`, `poll`, `wait`, `doctor`,
`list_agents`, `status`. The server reuses the same code path as the
CLI, so MCP tool calls and CLI calls behave identically.