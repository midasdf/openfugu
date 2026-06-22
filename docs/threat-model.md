# Threat Model

openfugu protects against accidental credential propagation, unverified
candidate acceptance, and cross-candidate context leakage.

It does not sandbox arbitrary code execution. Git worktrees are only change
isolation.
