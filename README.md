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

Task execution uses local scoring by default. Passing `--planner
subscription-agent` asks a subscription CLI to route the task first, then falls
back to local scoring if the router output is invalid. Add
`--explain-routing` to print the route, preferred agent, score, and selected
agent. Local scoring also uses prior accepted/failed outcomes from the local
ledger.

## Usage

```sh
openfugu --help
openfugu

# Run setup and dependency diagnostics
openfugu doctor

# View routing decisions and agent selection details
openfugu --explain-routing "your task"
```

Use the `--no-apply` flag to perform dry runs.

Running `openfugu` without arguments starts the ZigZag-based interactive TUI.
It uses raw-key input on an interactive terminal, so cursor movement and common
line-editing shortcuts work inside the fullscreen dashboard. Type a task to
route and execute it, or type `:quit` to exit.
The TUI also accepts `:doctor`, `:agents`, `:dry-run`, `:agent <name>`,
`:mode <name>`, `:planner <name>`, and `:clear`.
