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
