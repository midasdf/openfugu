# Architecture

openfugu separates planning, adapter invocation, process runtime, workspace
isolation, verification, and local observability.

Adapters describe official CLI compatibility and build argv arrays. They do not
own process lifecycle. The process runtime executes argv without shell strings.

The conductor records a clean source HEAD, creates candidate worktrees from that
base, runs objective verification in the candidate, applies accepted commits
with `cherry-pick --no-commit`, and reruns the same verification after apply.

The subscription planner path must validate model-proposed plans before use. If
the output is invalid, openfugu falls back to the deterministic heuristic
planner.

For task execution, `--planner subscription-agent` first asks a subscription CLI
for a small routing hint. The hint only affects local scoring after validation;
invalid hints are ignored.
