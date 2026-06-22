# Provider Compatibility

MVP targets official non-interactive modes for:

- Claude Code CLI: `claude`
- Codex CLI: `codex`
- Antigravity CLI: `agy`

Unknown versions are not treated as fully supported.

The default policy rejects API-key, unauthenticated, and unknown auth. The
adapter layer strips known API-key environment variables before child process
execution. Provider overage and quota state can be unavailable; unavailable is
reported as unknown, not safe.
