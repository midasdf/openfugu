const std = @import("std");
const openfugu = @import("openfugu");

test "subscription planner falls back to heuristic on invalid output" {
    var plan = try openfugu.subscription_agent.planOrFallback(std.testing.allocator, .{
        .original_request = "fix src/main.zig typo",
        .safe_repo_summary = "one file",
    }, "not json");
    defer openfugu.planner.deinitPlan(std.testing.allocator, &plan);

    try std.testing.expectEqual(openfugu.types.Topology.one_shot, plan.topology);
    try std.testing.expectEqual(openfugu.types.Role.worker, plan.nodes[0].role);
}

test "verdict rejects unverified candidate before objective verification" {
    var verification = openfugu.verify.Verification{
        .passed = false,
        .unverified = true,
        .commands = try std.testing.allocator.alloc(openfugu.verify.CommandResult, 0),
    };
    defer verification.deinit(std.testing.allocator);

    const verdict = openfugu.verdict.decide(.{
        .has_changes = true,
        .objective = verification,
        .model_review = .{ .required = false, .rejected = false },
        .reverified = false,
    });
    try std.testing.expectEqual(openfugu.verdict.Decision.reject, verdict);
}

test "policy skips cooldown agent and selects alternate after rate limit" {
    var agents = [_]openfugu.policy.AgentStats{
        .{
            .id = "claude",
            .vendor = "anthropic",
            .auth = .subscription,
            .compatibility = .supported,
            .busy = false,
            .cooldown_until_ms = 10_000,
            .recent_rate_limits = 1,
        },
        .{
            .id = "codex",
            .vendor = "openai",
            .auth = .subscription,
            .compatibility = .supported,
            .busy = false,
            .cooldown_until_ms = 0,
            .recent_rate_limits = 0,
        },
    };

    const selected = try openfugu.policy.chooseAgent(&agents, 1_000);
    try std.testing.expectEqualStrings("codex", selected.id);
}
