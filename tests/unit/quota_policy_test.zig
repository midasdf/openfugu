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

test "fast router hint rejects invalid json and scores preferred agent" {
    try std.testing.expect(openfugu.policy.parseRouterHint("not json") == null);
    const hint = openfugu.policy.parseRouterHint("text {\"task_kind\":\"terminal\",\"preferred_agent\":\"codex\"} tail") orelse return error.MissingHint;
    try std.testing.expectEqual(openfugu.policy.TaskKind.terminal, hint.kind.?);
    try std.testing.expectEqual(openfugu.policy.PreferredAgent.codex, hint.preferred_agent);
    try std.testing.expect(openfugu.policy.scoreAgent(.{
        .id = "codex",
        .profile_name = "codex",
        .kind = hint.kind.?,
        .preferred_agent = hint.preferred_agent,
    }) > openfugu.policy.scoreAgent(.{
        .id = "claude",
        .profile_name = "claude-code",
        .kind = hint.kind.?,
        .preferred_agent = hint.preferred_agent,
    }));
    const escaped = openfugu.policy.parseRouterHint("{\"message\":\"{\\\"task_kind\\\":\\\"review\\\",\\\"preferred_agent\\\":\\\"claude\\\"}\"}") orelse return error.MissingEscapedHint;
    try std.testing.expectEqual(openfugu.policy.TaskKind.review, escaped.kind.?);
    try std.testing.expectEqual(openfugu.policy.PreferredAgent.claude, escaped.preferred_agent);
}

test "policy routes frontend design work toward antigravity fallback" {
    const kind = openfugu.policy.classifyTask("polish the frontend UI layout");
    try std.testing.expectEqual(openfugu.policy.TaskKind.frontend, kind);
    try std.testing.expect(openfugu.policy.scoreAgent(.{
        .id = "agy",
        .profile_name = "antigravity",
        .kind = kind,
    }) > openfugu.policy.scoreAgent(.{
        .id = "codex",
        .profile_name = "codex",
        .kind = kind,
    }));
}

test "classifyTaskConfidence reports low confidence for keywordless text" {
    const classified = openfugu.policy.classifyTaskConfidence("do something");
    try std.testing.expectEqual(openfugu.policy.TaskKind.general, classified.kind);
    try std.testing.expectEqual(openfugu.policy.ClassifyConfidence.low, classified.confidence);
}

test "classifyTaskConfidence reports high confidence for japanese keywords" {
    const classified = openfugu.policy.classifyTaskConfidence("テストを修正する");
    try std.testing.expectEqual(openfugu.policy.TaskKind.test_fix, classified.kind);
    try std.testing.expectEqual(openfugu.policy.ClassifyConfidence.high, classified.confidence);
}

test "suggestAgent returns codex for terminal and test_fix" {
    try std.testing.expectEqual(openfugu.policy.PreferredAgent.codex, openfugu.policy.suggestAgent(.terminal));
    try std.testing.expectEqual(openfugu.policy.PreferredAgent.codex, openfugu.policy.suggestAgent(.test_fix));
    try std.testing.expectEqual(openfugu.policy.PreferredAgent.claude, openfugu.policy.suggestAgent(.bugfix));
    try std.testing.expectEqual(openfugu.policy.PreferredAgent.antigravity, openfugu.policy.suggestAgent(.frontend));
    try std.testing.expectEqual(openfugu.policy.PreferredAgent.none, openfugu.policy.suggestAgent(.general));
}

test "nearestCommand suggests close typo" {
    const known = [_][]const u8{ "help", "status", "agents", "plan" };
    const suggestion = openfugu.policy.nearestCommand("stat", &known);
    try std.testing.expectEqualStrings("status", suggestion orelse return error.MissingSuggestion);
    try std.testing.expect(openfugu.policy.nearestCommand("zzz", &known) == null);
}

test "scoreAgent penalises agents in active cooldown" {
    const hot = openfugu.policy.scoreAgent(.{
        .id = "codex",
        .profile_name = "codex",
        .kind = .terminal,
        .cooldown_until_ms = 10_000,
        .now_ms = 1_000,
    });
    const cold = openfugu.policy.scoreAgent(.{
        .id = "codex",
        .profile_name = "codex",
        .kind = .terminal,
        .cooldown_until_ms = 0,
        .now_ms = 1_000,
    });
    try std.testing.expect(hot < cold);
}

test "scoreAgent penalises agents lacking required capabilities" {
    const with_caps = openfugu.policy.scoreAgent(.{
        .id = "codex",
        .profile_name = "codex",
        .kind = .bugfix,
        .capability = .{ .edit_files = true, .run_commands = true },
    });
    const without_caps = openfugu.policy.scoreAgent(.{
        .id = "codex",
        .profile_name = "codex",
        .kind = .bugfix,
        .capability = .{ .edit_files = false, .run_commands = false },
    });
    try std.testing.expect(with_caps > without_caps);
}
