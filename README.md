# openfugu

openfugu is a local orchestration harness for official coding-agent CLIs that
the user has already installed and logged into.

The project is inspired by the coordination structures described in TRINITY and
Conductor, but it does not reproduce trained coordinator weights, private
routers, or benchmark claims from those papers.

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
