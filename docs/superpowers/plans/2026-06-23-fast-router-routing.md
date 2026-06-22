# Fast Router Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make task execution choose agents through a validated fast-router classification plus deterministic scoring, with fallback to the existing first-runnable behavior.

**Architecture:** Keep routing local and small. A fast router returns or implies a task kind; `policy.zig` scores runnable agents by task kind, subscription/auth/compatibility, cooldown, and recent success rate. `cli.zig` collects runnable candidates, sorts by policy score, then runs the best candidate first.

**Tech Stack:** Zig 0.16.0, existing fake CLI fixtures, existing `zig build test`.

---

### Task 1: Add Scored Agent Routing

**Files:**
- Modify: `src/conductor/policy.zig`
- Modify: `src/cli.zig`
- Test: `tests/unit/probe_test.zig`

- [x] **Step 1: Write the failing test**

Add a test where two runnable agents are available in `bad,good` order, the task says `fix tests`, and the router should choose the `good` agent first because test-fix tasks prefer the Codex-shaped profile.

- [x] **Step 2: Run the focused test**

Run: `zig build test`

Expected: FAIL because current execution picks the first runnable agent.

- [x] **Step 3: Write minimal implementation**

Add `TaskKind`, `classifyTask`, and `scoreAgent` to `policy.zig`. In `cli.zig`, collect runnable specs, sort by score, and run in score order.

- [x] **Step 4: Verify**

Run: `zig build test`

Expected: PASS.

- [x] **Step 5: Full checks**

Run:

```sh
zig build
zig build test
zig build smoke
zig fmt --check .
```

Expected: all commands exit 0.
