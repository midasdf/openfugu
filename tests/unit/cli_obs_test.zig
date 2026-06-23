const std = @import("std");
const openfugu = @import("openfugu");

test "cli fixture commands return plan doctor agents usage and replay text" {
    const plan = try openfugu.cli.runAlloc(std.testing.allocator, &.{ "openfugu", "plan", "fix typo" });
    defer std.testing.allocator.free(plan);
    try std.testing.expect(std.mem.indexOf(u8, plan, "one_shot") != null);

    const doctor = try openfugu.cli.runAlloc(std.testing.allocator, &.{ "openfugu", "doctor" });
    defer std.testing.allocator.free(doctor);
    try std.testing.expect(std.mem.indexOf(u8, doctor, "subscription-only") != null);

    const agents = try openfugu.cli.runAlloc(std.testing.allocator, &.{ "openfugu", "agents" });
    defer std.testing.allocator.free(agents);
    try std.testing.expect(std.mem.indexOf(u8, agents, "claude") != null);

    const usage = try openfugu.cli.runAlloc(std.testing.allocator, &.{ "openfugu", "usage", "--since", "1d" });
    defer std.testing.allocator.free(usage);
    try std.testing.expect(std.mem.indexOf(u8, usage, "unavailable") != null);

    const replay = try openfugu.cli.runAlloc(std.testing.allocator, &.{ "openfugu", "replay", "fixture-run" });
    defer std.testing.allocator.free(replay);
    try std.testing.expect(std.mem.indexOf(u8, replay, "fixture-run") != null);
}

test "plan accepts explicit subscription planner flag and reports fallback" {
    const plan = try openfugu.cli.runAlloc(std.testing.allocator, &.{ "openfugu", "plan", "--planner", "subscription-agent", "fix typo" });
    defer std.testing.allocator.free(plan);

    try std.testing.expect(std.mem.indexOf(u8, plan, "planner=subscription-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "fallback=heuristic") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "topology=one_shot") != null);
}

test "ledger omits content and redacts secret values by default" {
    const event = openfugu.ledger.Event{
        .run_id = "r1",
        .agent = "codex",
        .content = "prompt with OPENAI_API_KEY=value-to-redact",
        .include_content = false,
    };
    const line = try openfugu.ledger.format(std.testing.allocator, event);
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "value-to-redact") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "prompt with") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "content_hash") != null);
}

test "ledger includes verification and apply metadata without content" {
    const line = try openfugu.ledger.format(std.testing.allocator, .{
        .run_id = "r1",
        .agent = "codex",
        .content = "secret prompt",
        .include_content = false,
        .verification_passed = true,
        .accepted = true,
        .applied = true,
        .reverified = true,
    });
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "\"verification_passed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"accepted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"applied\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"reverified\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "secret prompt") == null);
}

test "ledger append creates owner-only jsonl file without secret content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const path = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "ledger.jsonl" });
    defer std.testing.allocator.free(path);

    try openfugu.ledger.append(std.testing.allocator, std.testing.io, path, .{
        .run_id = "r1",
        .agent = "codex",
        .content = "OPENAI_API_KEY=value-to-redact",
        .include_content = false,
    });
    try openfugu.ledger.append(std.testing.allocator, std.testing.io, path, .{
        .run_id = "r2",
        .agent = "claude",
        .content = "second event",
        .include_content = false,
    });

    const line = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "content_hash") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "value-to-redact") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"run\":\"r1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"run\":\"r2\"") != null);

    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "usage summary distinguishes unavailable token counts" {
    const events = [_]openfugu.usage.Event{
        .{ .agent = "codex", .reported_tokens = null, .rate_limited = true, .ok = false },
        .{ .agent = "codex", .reported_tokens = 12, .rate_limited = false, .ok = true },
    };
    const summary = openfugu.usage.summarize(&events);

    try std.testing.expectEqual(@as(u64, 2), summary.calls);
    try std.testing.expectEqual(@as(u64, 12), summary.reported_tokens);
    try std.testing.expectEqual(@as(u64, 1), summary.unavailable_tokens);
    try std.testing.expectEqual(@as(u64, 1), summary.rate_limits);
}

test "usage cli reads ledger events from runtime directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "repo" });
    defer std.testing.allocator.free(root);
    const worktrees = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "worktrees" });
    defer std.testing.allocator.free(worktrees);
    const ledger_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "ledger.jsonl" });
    defer std.testing.allocator.free(ledger_path);

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.createDirPath(std.testing.io, "worktrees");
    try openfugu.ledger.append(std.testing.allocator, std.testing.io, ledger_path, .{
        .run_id = "r1",
        .agent = "codex",
        .content = "first",
        .accepted = true,
    });
    try openfugu.ledger.append(std.testing.allocator, std.testing.io, ledger_path, .{
        .run_id = "r2",
        .agent = "claude",
        .content = "second",
        .accepted = false,
    });

    var result = try openfugu.cli.runWithProbeSpecsInRepo(
        std.testing.allocator,
        std.testing.io,
        &.{ "openfugu", "usage", "--since", "1d" },
        &.{},
        root,
        worktrees,
        &.{},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(openfugu.cli.exit_ok, result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "calls=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "successes=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "failures=1") != null);
}

test "replay cli reads ledger without reexecuting children" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "repo" });
    defer std.testing.allocator.free(root);
    const worktrees = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "worktrees" });
    defer std.testing.allocator.free(worktrees);
    const ledger_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "ledger.jsonl" });
    defer std.testing.allocator.free(ledger_path);

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.createDirPath(std.testing.io, "worktrees");
    try openfugu.ledger.append(std.testing.allocator, std.testing.io, ledger_path, .{
        .run_id = "run-123",
        .agent = "codex",
        .content = "prompt",
        .accepted = true,
        .reverified = true,
    });

    var result = try openfugu.cli.runWithProbeSpecsInRepo(
        std.testing.allocator,
        std.testing.io,
        &.{ "openfugu", "replay", "run-123" },
        &.{},
        root,
        worktrees,
        &.{},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(openfugu.cli.exit_ok, result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "run-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "no-child-process-reexecuted") != null);
}

test "trace line includes required orchestration fields" {
    const line = try openfugu.trace.line(std.testing.allocator, .{
        .turn = 1,
        .depth = 2,
        .node = "n1",
        .agent = "codex",
        .role = .worker,
        .intent = .implement,
        .planner = "heuristic",
        .verification = "passed",
        .accepted = true,
    });
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "turn=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "depth=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "node=n1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "agent=codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "role=worker") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "intent=implement") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "planner=heuristic") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "verification=passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "accepted=true") != null);
}

test "recovery reports clean state when no process worktree branch or lock remains" {
    const result = openfugu.recovery.audit(.{
        .processes = 0,
        .worktrees = 0,
        .branches = 0,
        .locks = 0,
    });
    try std.testing.expect(result.clean);
}

test "task execution without runnable subscription agent returns exit 3" {
    var result = try openfugu.cli.run(std.testing.allocator, &.{ "openfugu", "fix the bug" });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(openfugu.cli.exit_no_agent, result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "no subscription-compatible agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "not-run") == null);
}

test "mode flags still fail closed when no agent is runnable" {
    var result = try openfugu.cli.run(std.testing.allocator, &.{ "openfugu", "--mode", "single", "fix the bug" });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(openfugu.cli.exit_no_agent, result.code);
}

test "invalid task flags return usage errors" {
    try std.testing.expectError(error.InvalidArgs, openfugu.cli.run(std.testing.allocator, &.{ "openfugu", "--mode" }));
    try std.testing.expectError(error.InvalidArgs, openfugu.cli.run(std.testing.allocator, &.{ "openfugu", "--bogus", "fix" }));
    try std.testing.expectError(error.InvalidArgs, openfugu.cli.run(std.testing.allocator, &.{ "openfugu", "--mode", "bogus", "fix" }));
    try std.testing.expectError(error.InvalidArgs, openfugu.cli.runAlloc(std.testing.allocator, &.{ "openfugu", "plan", "--planner", "bogus", "fix" }));
}

test "help prints cli usage" {
    const help = try openfugu.cli.runAlloc(std.testing.allocator, &.{ "openfugu", "--help" });
    defer std.testing.allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "Usage: openfugu") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "openfugu doctor") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-apply") != null);
}

test "numbered file view prefixes lines" {
    const text = try openfugu.cli.numberedLines(std.testing.allocator, "alpha\nbeta\n");
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("   1 | alpha\n   2 | beta\n", text);
}

test "open spec accepts optional line suffix" {
    const spec = openfugu.cli.parseOpenSpec("src/main.zig:42");

    try std.testing.expectEqualStrings("src/main.zig", spec.path);
    try std.testing.expectEqual(@as(?usize, 42), spec.line);
}

test "interactive input classifies prompt lines" {
    try std.testing.expectEqualStrings("fix README", openfugu.cli.interactiveInput("  fix README\n").task);
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.empty, openfugu.cli.interactiveInput(" \n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.quit, openfugu.cli.interactiveInput(":quit\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.clear, openfugu.cli.interactiveInput(":clear\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.clear_history, openfugu.cli.interactiveInput(":clear-history\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.history, openfugu.cli.interactiveInput(":history\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.doctor, openfugu.cli.interactiveInput(":doctor\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.agents, openfugu.cli.interactiveInput(":agents\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.usage, openfugu.cli.interactiveInput(":usage\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.ledger, openfugu.cli.interactiveInput(":ledger\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.where_, openfugu.cli.interactiveInput(":where\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.where_, openfugu.cli.interactiveInput(":pwd\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.worktrees, openfugu.cli.interactiveInput(":worktrees\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.git, openfugu.cli.interactiveInput(":git\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.branch, openfugu.cli.interactiveInput(":branch\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.log, openfugu.cli.interactiveInput(":log\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.diff, openfugu.cli.interactiveInput(":diff\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.staged, openfugu.cli.interactiveInput(":staged\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.patch, openfugu.cli.interactiveInput(":patch\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.ci, openfugu.cli.interactiveInput(":ci\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.watch_ci, openfugu.cli.interactiveInput(":watch-ci\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.verify, openfugu.cli.interactiveInput(":verify\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.build, openfugu.cli.interactiveInput(":build\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.test_, openfugu.cli.interactiveInput(":test\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.fmt, openfugu.cli.interactiveInput(":fmt\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.check, openfugu.cli.interactiveInput(":check\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.cancel, openfugu.cli.interactiveInput(":cancel\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.help, openfugu.cli.interactiveInput(":help\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.status, openfugu.cli.interactiveInput(":status\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.reset_routing, openfugu.cli.interactiveInput(":reset-routing\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.dry_run, openfugu.cli.interactiveInput(":dry-run\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.no_apply, openfugu.cli.interactiveInput(":no-apply\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.apply, openfugu.cli.interactiveInput(":apply\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.rerun, openfugu.cli.interactiveInput(":rerun\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.fetch, openfugu.cli.interactiveInput(":fetch\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.pull, openfugu.cli.interactiveInput(":pull\n"));
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.push, openfugu.cli.interactiveInput(":push\n"));
    try std.testing.expectEqualStrings("out.txt", openfugu.cli.interactiveInput(":save out.txt\n").save);
    try std.testing.expectEqualStrings("README.md", openfugu.cli.interactiveInput(":stage README.md\n").stage);
    try std.testing.expectEqualStrings("README.md", openfugu.cli.interactiveInput(":unstage README.md\n").unstage);
    try std.testing.expectEqualStrings("add tui command", openfugu.cli.interactiveInput(":commit add tui command\n").commit);
    try std.testing.expectEqualStrings("echo ok", openfugu.cli.interactiveInput(":run echo ok\n").run);
    try std.testing.expectEqualStrings("needle", openfugu.cli.interactiveInput(":rg needle\n").rg);
    try std.testing.expectEqual(openfugu.cli.InteractiveInput.todo, openfugu.cli.interactiveInput(":todo\n"));
    try std.testing.expectEqualStrings(".", openfugu.cli.interactiveInput(":ls\n").ls);
    try std.testing.expectEqualStrings("src", openfugu.cli.interactiveInput(":ls src\n").ls);
    try std.testing.expectEqualStrings(".", openfugu.cli.interactiveInput(":files\n").files);
    try std.testing.expectEqualStrings("src", openfugu.cli.interactiveInput(":files src\n").files);
    try std.testing.expectEqualStrings("/tmp", openfugu.cli.interactiveInput(":cd /tmp\n").cwd);
    try std.testing.expectEqualStrings("/tmp", openfugu.cli.interactiveInput(":cwd /tmp\n").cwd);
    try std.testing.expectEqualStrings("task.md", openfugu.cli.interactiveInput(":load task.md\n").load);
    try std.testing.expectEqualStrings("README.md", openfugu.cli.interactiveInput(":open README.md\n").open);
    try std.testing.expectEqualStrings("README.md", openfugu.cli.interactiveInput(":head README.md\n").head);
    try std.testing.expectEqualStrings("logs/app.log", openfugu.cli.interactiveInput(":tail logs/app.log\n").tail);
    try std.testing.expectEqualStrings("fix typo", openfugu.cli.interactiveInput(":plan fix typo\n").plan);
    try std.testing.expectEqualStrings("fix failing tests", openfugu.cli.interactiveInput(":route fix failing tests\n").route);
    try std.testing.expectEqualStrings("run-123", openfugu.cli.interactiveInput(":replay run-123\n").replay);
    try std.testing.expectEqualStrings("codex", openfugu.cli.interactiveInput(":agent codex\n").agent);
    try std.testing.expectEqualStrings("race", openfugu.cli.interactiveInput(":mode race\n").mode);
    try std.testing.expectEqualStrings("subscription-agent", openfugu.cli.interactiveInput(":planner subscription-agent\n").planner);
}

test "tui render draws fullscreen frame" {
    const screen = try openfugu.tui.render(std.testing.allocator, "ready", "fix README", "router=heuristic\n");
    defer std.testing.allocator.free(screen);

    try std.testing.expect(std.mem.indexOf(u8, screen, "\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "openfugu") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "> fix README") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "router=heuristic") != null);
}

test "tui render uses viewport and command help" {
    const screen = try openfugu.tui.render(std.testing.allocator, "ready", "", "line1\nline2\nline3\n");
    defer std.testing.allocator.free(screen);

    try std.testing.expect(std.mem.indexOf(u8, screen, ":help commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "line3") != null);
}

test "tui render accepts terminal dimensions" {
    const screen = try openfugu.tui.renderSized(std.testing.allocator, "ready", "", "ok\n", 72, 18);
    defer std.testing.allocator.free(screen);

    try std.testing.expect(std.mem.indexOf(u8, screen, "ok") != null);
}

test "tui dashboard includes agents and history" {
    const screen = try openfugu.tui.renderDashboardSized(std.testing.allocator, .{
        .status = "ready apply",
        .input = "fix test",
        .output = "router=heuristic\n",
        .agents = "claude runnable\ncodex runnable\nagy runnable\n",
        .history = "fix test\n",
    }, 90, 24);
    defer std.testing.allocator.free(screen);

    try std.testing.expect(std.mem.indexOf(u8, screen, "Agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "claude runnable") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "History") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "fix test") != null);
}

test "tui dashboard can show output from top" {
    const output =
        \\top-line
        \\middle-line-1
        \\middle-line-2
        \\middle-line-3
        \\middle-line-4
        \\middle-line-5
        \\bottom-line
        \\
    ;
    const top_screen = try openfugu.tui.renderDashboardSized(std.testing.allocator, .{
        .status = "ready apply",
        .input = "",
        .output = output,
        .output_bottom = false,
        .agents = "claude runnable\n",
        .history = "No tasks yet.\n",
    }, 80, 14);
    defer std.testing.allocator.free(top_screen);
    const bottom_screen = try openfugu.tui.renderDashboardSized(std.testing.allocator, .{
        .status = "ready apply",
        .input = "",
        .output = output,
        .output_bottom = true,
        .agents = "claude runnable\n",
        .history = "No tasks yet.\n",
    }, 80, 14);
    defer std.testing.allocator.free(bottom_screen);

    try std.testing.expect(std.mem.indexOf(u8, top_screen, "top-line") != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom_screen, "bottom-line") != null);
}

test "tui dashboard accepts output offset" {
    const output =
        \\line-0
        \\line-1
        \\line-2
        \\line-3
        \\line-4
        \\line-5
        \\line-6
        \\line-7
        \\
    ;
    const screen = try openfugu.tui.renderDashboardSized(std.testing.allocator, .{
        .status = "ready apply",
        .input = "",
        .output = output,
        .output_bottom = false,
        .output_offset = 2,
        .agents = "claude runnable\n",
        .history = "No tasks yet.\n",
    }, 80, 14);
    defer std.testing.allocator.free(screen);

    try std.testing.expect(std.mem.indexOf(u8, screen, "line-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "line-7") == null);
}
