const std = @import("std");
const openfugu = @import("openfugu");

test "official adapters build non-interactive invocations by role" {
    const task: openfugu.types.Task = .{
        .id = "t1",
        .role = .worker,
        .intent = .implement,
        .instruction = "fix the bug",
        .worktree_path = "/tmp/work",
        .context = "ctx",
        .target_files = &.{},
        .timeout_ms = 1000,
        .read_only = false,
    };

    var claude = try openfugu.claude_code.buildInvocation(std.testing.allocator, .supported_1, task);
    defer claude.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("claude", claude.value.executable);
    try containsArg(claude.value.argv, "-p");
    try containsArg(claude.value.argv, "--output-format");
    try containsArg(claude.value.argv, "stream-json");
    try containsArg(claude.value.argv, "--verbose");
    try containsArg(claude.value.argv, "acceptEdits");
    try noDangerousArg(claude.value.argv);

    var codex = try openfugu.codex.buildInvocation(std.testing.allocator, .supported_1, task);
    defer codex.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("codex", codex.value.executable);
    try containsArg(codex.value.argv, "exec");
    try containsArg(codex.value.argv, "--sandbox");
    try containsArg(codex.value.argv, "workspace-write");
    try noDangerousArg(codex.value.argv);

    var agy = try openfugu.antigravity.buildInvocation(std.testing.allocator, .degraded_text, task);
    defer agy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("agy", agy.value.executable);
    try containsArg(agy.value.argv, "-p");
    try std.testing.expectEqual(openfugu.types.OutputFormat.text, agy.value.output_format);
    try noDangerousArg(agy.value.argv);
}

test "claude thinker uses plan mode" {
    const task: openfugu.types.Task = .{
        .id = "t1",
        .role = .thinker,
        .intent = .analyze,
        .instruction = "inspect",
        .worktree_path = "/tmp/work",
        .context = "ctx",
        .target_files = &.{},
        .timeout_ms = 1000,
        .read_only = true,
    };

    var claude = try openfugu.claude_code.buildInvocation(std.testing.allocator, .supported_1, task);
    defer claude.deinit(std.testing.allocator);
    try containsArg(claude.value.argv, "plan");
}

test "unknown versions are not treated as supported" {
    try std.testing.expectEqual(openfugu.types.Compatibility.unknown, openfugu.claude_code.profileForVersion("unverified").compatibility);
    try std.testing.expectEqual(openfugu.types.Compatibility.unknown, openfugu.codex.profileForVersion("unverified").compatibility);
    try std.testing.expectEqual(openfugu.types.Compatibility.unknown, openfugu.antigravity.profileForVersion("unverified").compatibility);
}

test "locally verified version prefixes are treated as compatible" {
    try std.testing.expectEqual(openfugu.types.Compatibility.supported, openfugu.claude_code.profileForVersion("2.1.183 (Claude Code)").compatibility);
    try std.testing.expectEqual(openfugu.types.Compatibility.supported, openfugu.codex.profileForVersion("codex-cli 0.141.0").compatibility);
    try std.testing.expectEqual(openfugu.types.Compatibility.degraded, openfugu.antigravity.profileForVersion("1.0.10").compatibility);
}

test "subscription-only rejects api key unauthenticated and unknown auth" {
    const cfg = openfugu.config.Config.default();
    const profile = openfugu.claude_code.profileForVersion("supported-1");

    try std.testing.expect(openfugu.adapter.runnable(cfg.subscription, profile, .subscription));
    try std.testing.expect(!openfugu.adapter.runnable(cfg.subscription, profile, .api_key));
    try std.testing.expect(!openfugu.adapter.runnable(cfg.subscription, profile, .unauthenticated));
    try std.testing.expect(!openfugu.adapter.runnable(cfg.subscription, profile, .unknown));
}

fn containsArg(argv: []const []const u8, expected: []const u8) !void {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, expected)) return;
    }
    return error.MissingArg;
}

fn noDangerousArg(argv: []const []const u8) !void {
    for (argv) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "--dangerously") == null);
        try std.testing.expect(!std.mem.eql(u8, arg, "--yolo"));
    }
}
