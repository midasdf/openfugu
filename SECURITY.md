# Security

Report security issues privately to the maintainers.

openfugu must not log secrets, read vendor credential stores, or treat
worktrees as a security sandbox. Normal tests must not contact real CLIs or
external services.
