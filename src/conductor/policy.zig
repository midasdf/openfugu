const std = @import("std");
const types = @import("../core/types.zig");

pub const TaskKind = enum {
    general,
    bugfix,
    test_fix,
    refactor,
    terminal,
    review,
    broad,
};

pub const PreferredAgent = enum {
    none,
    claude,
    codex,
    antigravity,
};

pub const RouterHint = struct {
    kind: ?TaskKind = null,
    preferred_agent: PreferredAgent = .none,
};

pub const AgentStats = struct {
    id: []const u8,
    vendor: []const u8,
    auth: types.AuthKind,
    compatibility: types.Compatibility,
    busy: bool = false,
    cooldown_until_ms: u64 = 0,
    recent_rate_limits: u32 = 0,
    calls: u64 = 0,
    successes: u64 = 0,
    failures: u64 = 0,
};

pub fn chooseAgent(agents: []const AgentStats, now_ms: u64) !AgentStats {
    for (agents) |agent| {
        if (agent.busy) continue;
        if (agent.cooldown_until_ms > now_ms) continue;
        if (agent.compatibility != .supported and agent.compatibility != .degraded) continue;
        if (agent.auth != .subscription and agent.auth != .organization_subscription) continue;
        return agent;
    }
    return error.NoAvailableAgent;
}

pub const ScoreInput = struct {
    id: []const u8,
    profile_name: []const u8,
    kind: TaskKind,
    preferred_agent: PreferredAgent = .none,
    calls: u64 = 0,
    successes: u64 = 0,
    failures: u64 = 0,
};

pub fn classifyTask(text: []const u8) TaskKind {
    if (hasAny(text, &.{ "test", "spec", "failing", "failure" })) return .test_fix;
    if (hasAny(text, &.{ "terminal", "shell", "command", "script" })) return .terminal;
    if (hasAny(text, &.{ "review", "audit", "security" })) return .review;
    if (hasAny(text, &.{ "refactor", "rename", "cleanup" })) return .refactor;
    if (hasAny(text, &.{ "bug", "fix", "crash", "error" })) return .bugfix;
    if (hasAny(text, &.{ "broad", "architecture", "design" })) return .broad;
    return .general;
}

pub fn scoreAgent(input: ScoreInput) i64 {
    var score: i64 = 100;
    if (preferredMatches(input)) score += 100;
    switch (input.kind) {
        .test_fix, .terminal => {
            if (isCodex(input)) score += 30;
            if (isClaude(input)) score += 10;
        },
        .bugfix, .refactor, .review, .broad => {
            if (isClaude(input)) score += 25;
            if (isCodex(input)) score += 15;
        },
        .general => {
            if (isClaude(input)) score += 10;
            if (isCodex(input)) score += 10;
        },
    }
    if (isAntigravity(input)) score += 5;
    if (input.calls != 0) {
        score += @as(i64, @intCast(input.successes * 10));
        score -= @as(i64, @intCast(input.failures * 15));
    }
    return score;
}

pub fn parseRouterHint(raw: []const u8) ?RouterHint {
    const trimmed = std.mem.trim(u8, raw, " \n\r\t");
    const start = std.mem.indexOfScalar(u8, trimmed, '{') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return null;
    if (end <= start) return null;
    const json = trimmed[start .. end + 1];
    var hint: RouterHint = .{};
    if (jsonString(json, "\"task_kind\"") orelse jsonString(trimmed, "\\\"task_kind\\\"")) |value| {
        hint.kind = taskKindFromString(value) orelse return null;
    }
    if (jsonString(json, "\"preferred_agent\"") orelse jsonString(trimmed, "\\\"preferred_agent\\\"")) |value| {
        hint.preferred_agent = preferredAgentFromString(value) orelse return null;
    }
    if (hint.kind == null and hint.preferred_agent == .none) return null;
    return hint;
}

pub fn recordRateLimit(agent: *AgentStats, now_ms: u64) void {
    agent.recent_rate_limits += 1;
    agent.cooldown_until_ms = now_ms + backoffMs(agent.recent_rate_limits);
}

fn isClaude(input: ScoreInput) bool {
    return containsIgnoreCase(input.id, "claude") or containsIgnoreCase(input.profile_name, "claude");
}

fn isCodex(input: ScoreInput) bool {
    return containsIgnoreCase(input.id, "codex") or containsIgnoreCase(input.profile_name, "codex");
}

fn isAntigravity(input: ScoreInput) bool {
    return containsIgnoreCase(input.id, "agy") or containsIgnoreCase(input.profile_name, "antigravity");
}

fn preferredMatches(input: ScoreInput) bool {
    return switch (input.preferred_agent) {
        .none => false,
        .claude => isClaude(input),
        .codex => isCodex(input),
        .antigravity => isAntigravity(input),
    };
}

fn taskKindFromString(value: []const u8) ?TaskKind {
    if (std.mem.eql(u8, value, "general")) return .general;
    if (std.mem.eql(u8, value, "bugfix")) return .bugfix;
    if (std.mem.eql(u8, value, "test_fix")) return .test_fix;
    if (std.mem.eql(u8, value, "refactor")) return .refactor;
    if (std.mem.eql(u8, value, "terminal")) return .terminal;
    if (std.mem.eql(u8, value, "review")) return .review;
    if (std.mem.eql(u8, value, "broad")) return .broad;
    return null;
}

fn preferredAgentFromString(value: []const u8) ?PreferredAgent {
    if (std.mem.eql(u8, value, "claude")) return .claude;
    if (std.mem.eql(u8, value, "codex")) return .codex;
    if (std.mem.eql(u8, value, "agy") or std.mem.eql(u8, value, "antigravity")) return .antigravity;
    return null;
}

fn jsonString(raw: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, raw, key_pos + key.len, ':') orelse return null;
    const first_quote = std.mem.indexOfScalarPos(u8, raw, colon + 1, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, raw, first_quote + 1, '"') orelse return null;
    const value = raw[first_quote + 1 .. second_quote];
    if (value.len != 0 and value[value.len - 1] == '\\') return value[0 .. value.len - 1];
    return value;
}

fn hasAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(text, needle)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and std.ascii.toLower(haystack[i + j]) == std.ascii.toLower(needle[j])) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

fn backoffMs(rate_limits: u32) u64 {
    const shift: u6 = @intCast(@min(rate_limits, 6));
    return @as(u64, 1000) << shift;
}
