# openfugu

An experimental project that makes heavy use of LLM-generated code.
It was inspired by Sakana AI's Fugu Ultra and the related papers.
The official Sakana subscription is quite expensive, so I wanted to build an open version that you can use as long as you have subscriptions to Claude Code, Codex, and Antigravity (you need all three)—and that's why I'm sharing it here.
Issues and pull requests are very welcome!

## Boundaries

- openfugu is architecture-inspired by Sakana AI's Fugu Ultra and related
  research papers; it is not a reproduction of trained coordinators, private
  routers, or benchmark claims from those papers.
- openfugu is not affiliated with, endorsed by, or sponsored by Anthropic,
  OpenAI, Google, or Sakana AI.
- openfugu does not call vendor model APIs directly.
- openfugu does not read, store, or reuse API keys, OAuth tokens, cookies, or
  keychain secrets.
- The default policy is subscription-only. API-key, unauthenticated, and unknown
  auth are rejected unless a future explicit policy says otherwise.
- Vendor CLI use follows the user's plan, limits, organization policy, and
  provider-side overage settings. Additional provider-side charges can still
  happen when the provider account allows them.
- Git worktrees isolate candidate changes, but they are not a security sandbox.

## Build

```sh
zig build
zig build test
zig fmt --check .
```

Zig 0.16.0 is required.

## Install

```sh
zig build install -p ~/.local
```

Make sure `~/.local/bin` is on `PATH`, then run:

```sh
openfugu --help
openfugu doctor
```

## Coding-agent skill

`skills/openfugu/SKILL.md` is a bundled skill for coding agents
(opencode, Claude Code, Codex). Install it into your agent's skills
directory (e.g. `~/.agents/skills/openfugu/SKILL.md`) and the agent can
route tasks through openfugu using the recommended
`doctor -> route -> run` flow. The skill documents the subcommands,
planners, exit codes, and task-kind vocabulary so the agent never has
to read `--help` to discover the interface.

Real CLI smoke checks are opt-in because they can consume provider quota:

```sh
zig build smoke -Dreal-cli-tests=true
```

Model-invoking task smoke checks require a second opt-in. This command asks
the provider CLIs to run a real task and can consume subscription quota:

```sh
zig build smoke -Dreal-cli-tests=true -Dreal-cli-task-tests=true
```

The normal test suite uses fake agents and temporary git repositories only.

Task execution uses the subscription-agent planner by default. It asks an
available subscription CLI to route the task first, then falls back to local
scoring if the router output is invalid. Pass `--planner heuristic` to skip the
subscription router, or `--planner capability` to use a deterministic
capability-aware planner that gates agents on edit_files / run_commands /
structured_output. Add `--explain-routing` to print the route, preferred
agent, score, and selected agent. Local scoring also uses prior accepted/failed
outcomes from the local ledger.

## Usage

```sh
openfugu --help
openfugu

# Inspect routing without running (no quota consumed)
openfugu route "your task"

# Route and execute
openfugu run "your task"

# Fire a task and return immediately; poll or wait for the result
openfugu submit "your task"
openfugu poll <job-id>
openfugu wait <job-id>
openfugu jobs

# Dry run (candidate worktree only, no apply)
openfugu run --no-apply "your task"

# Setup and dependency diagnostics
openfugu doctor

# Agent and ledger summary
openfugu status
openfugu list-agents

# View routing decisions and agent selection details
openfugu --explain-routing "your task"
```

Both `--flag value` and `--flag=value` are accepted. The explicit
subcommands `route` and `run` are the recommended entry points for
coding agents because they avoid ambiguity about what is a flag and
what is the task text. The positional form (`openfugu "task"`) still
works for backward compatibility.

Use the `--no-apply` flag to perform dry runs.

Running `openfugu` without arguments starts the ZigZag-based interactive TUI.
It uses raw-key input on an interactive terminal, so cursor movement and common
line-editing shortcuts work inside the fullscreen dashboard. Type a task to
route and execute it, press Tab to accept command suggestions, use Up/Down for
input history, press PageUp/PageDown to page output, use Home/End to jump to
the output top or bottom, or type `:quit` to exit.
Input history is stored in `.openfugu/tui-history`.
The TUI starts in `agent=auto`, `mode=auto`, `planner=subscription-agent`; use
`:planner heuristic` only when you want local scoring without the subscription
router.
The TUI also accepts `:status`, `:doctor`, `:agents`, `:usage`, `:ledger`,
`:where`, `:pwd`, `:worktrees`, `:git`, `:changed`, `:remote`, `:branch`, `:branches`, `:tags`, `:describe`, `:log`, `:diff`, `:staged`, `:staged-patch`, `:patch`, `:ci`, `:watch-ci`, `:pr`, `:pr <number-or-url>`, `:pr-checkout <number-or-url>`, `:issues`, `:issue <number-or-url>`, `:verify`, `:build`, `:test`, `:fmt`, `:check`, `:fetch`, `:pull`, `:push`, `:push-force-with-lease`, `:stash`, `:stashes`, `:stash-show`, `:stash-patch`, `:stash-pop`, `:cancel`,
`:rerun`, `:save <file>`, `:stage <path>`, `:unstage <path>`, `:commit <message>`, `:commit-amend <message>`, `:commit-amend-no-edit`, `:switch <branch>`, `:new-branch <branch>`, `:show <rev>`, `:run <command>`, `:rg <pattern>`, `:todo`, `:ls [path]`, `:files [path]`,
`:cd <path>`, `:cwd <path>`, `:load <file>`,
`:open <file[:line]>` with line numbers, `:head <file>`, `:tail <file>`, `:dry-run`, `:no-apply`, `:apply`,
`:agent <name>`, `:mode <name>`, `:planner <name>`, `:reset-routing`,
`:plan [task]`, `:route [task]`, `:last`, `:replay <run-id>`, `:clear`, `:history`, and
`:clear-history`.
Agent names accept `claude`, `claudecode`, `claude-code`, `codex`, `agy`, and
`antigravity`.
