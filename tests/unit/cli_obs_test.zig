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
