# Threat Model

openfugu protects against accidental credential propagation, unverified
candidate acceptance, and cross-candidate context leakage.

It does not sandbox arbitrary code execution. Git worktrees are only change
isolation.

openfugu does not read OAuth stores, cookies, keychains, or vendor session
files. It invokes official local CLI binaries through argv arrays and does not
contain a direct vendor HTTP model API path.

Ledger content storage is off by default. When content storage is disabled,
events record metadata and a content hash rather than prompt or source text.
