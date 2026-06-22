const std = @import("std");
const openfugu = @import("openfugu");

test "config validation rejects unknown fields with field name" {
    try std.testing.expectError(error.UnknownField, openfugu.config.validateText("subscription.only=true\nsurprise_field=true\n"));

    const msg = try openfugu.config.validateTextAlloc(std.testing.allocator, "subscription.only=true\nsurprise_field=true\n");
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "surprise_field") != null);
}

test "repo openfugu zon validates known subscription fields" {
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "openfugu.zon", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(text);
    try openfugu.config.validateText(text);
}

test "doctor render reports concrete git worktree and adapter states without unchecked" {
    const reports = [_]openfugu.probe.AgentReport{
        .{
            .name = "claude",
            .compatibility = .supported,
            .auth = .subscription,
            .runnable = true,
            .exists = true,
            .version = "supported-1",
            .non_interactive = true,
            .structured_output = true,
            .overage_known = false,
        },
        .{
            .name = "codex",
            .compatibility = .unknown,
            .auth = .unknown,
            .runnable = false,
            .exists = false,
            .version = "",
            .non_interactive = false,
            .structured_output = false,
            .overage_known = false,
        },
    };

    const rendered = try openfugu.doctor.render(std.testing.allocator, .{
        .config_ok = true,
        .git_ok = true,
        .worktree_ok = true,
        .subscription_only = true,
        .agents = &reports,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "git=ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "worktree=ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "claude exists=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "overage=unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "unchecked") == null);
}
