# openfugu

An experimental project that makes heavy use of LLM-generated code.
It was inspired by Sakana AI's Fugu Ultra and the related papers.
The official Sakana subscription is quite expensive, so I wanted to build an open version that you can use as long as you have subscriptions to Claude Code, Codex, and Antigravity (you need all three)—and that's why I'm sharing it here.
Issues and pull requests are very welcome!

## Boundaries

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

Real CLI smoke checks are opt-in because they can consume provider quota:

```sh
zig build smoke -Dreal-cli-tests=true
```

The normal test suite uses fake agents and temporary git repositories only.
