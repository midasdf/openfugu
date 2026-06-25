const std = @import("std");
const types = @import("../core/types.zig");

pub const TaskKind = enum {
    general,
    bugfix,
    test_fix,
    refactor,
    terminal,
    review,
    frontend,
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
    capability: types.Capability = .{},
    cooldown_until_ms: u64 = 0,
    now_ms: u64 = 0,
    recent_rate_limits: u32 = 0,
};

/// classifyTask uses an ordered, priority-ranked keyword table. Earlier
/// entries win over later ones, which resolves ambiguous cases like
/// "refactor the failing test" (test_fix wins because it appears earlier
/// and is more specific). Both English and Japanese keywords are supported.
pub fn classifyTask(text: []const u8) TaskKind {
    // High-specificity kinds first: terminal/script and test/spec are the
    // least ambiguous and should beat generic verbs like "fix".
    if (hasAny(text, &.{
        "terminal", "shell", "command", "script", "cli",
        "ターミナル",
        "シェル",
        "コマンド",
        "スクリプト",
    })) return .terminal;
    if (hasAny(text, &.{
        "test",       "spec", "failing", "failure", "flake", "flaky", "regression",
        "テスト",
        "失敗",
        "regression",
    })) return .test_fix;
    if (hasAny(text, &.{
        "review", "audit", "security", "vulnerab", "cve",
        "レビュー",
        "監査",
        "セキュリティ",
        "脆弱",
    })) return .review;
    if (hasAny(text, &.{
        "frontend", "ui",     "ux", "layout", "design", "web app", "css", "react",
        "vue",      "svelte",
        "フロントエンド",
        "画面",
        "レイアウト",
        "デザイン",
    })) return .frontend;
    if (hasAny(text, &.{
        "refactor", "rename", "cleanup", "restructure", "modernize",
        "リファクタ",
        "リネーム",
        "整理",
        "再構成",
    })) return .refactor;
    if (hasAny(text, &.{
        "bug",    "fix", "crash", "error", "broken", "regress", "wrong",
        "バグ",
        "修正",
        " crash",
        "エラー",
        "壊れ",
    })) return .bugfix;
    if (hasAny(text, &.{
        "broad", "architecture", "design", "investigate", "unclear", "explore",
        "全体",
        "アーキテクチャ",
        "調査",
        "不明",
    })) return .broad;
    return .general;
}

pub fn scoreAgent(input: ScoreInput) i64 {
    var score: i64 = 100;
    if (preferredMatches(input)) score += 100;

    // Capability gating: agents that structurally cannot do the work are
    // penalised hard. This makes the score honest about feasibility, not
    // just preference.
    if (requiresFileEdits(input.kind) and !input.capability.edit_files) score -= 200;
    if (requiresCommands(input.kind) and !input.capability.run_commands) score -= 200;
    if (requiresReadOnly(input.kind) and !input.capability.read_only_mode) score -= 20;

    switch (input.kind) {
        .test_fix, .terminal => {
            if (isCodex(input)) score += 60;
            if (isClaude(input)) score += 15;
            if (isAntigravity(input)) score -= 30;
        },
        .bugfix, .refactor, .review, .broad => {
            if (isClaude(input)) score += 25;
            if (isCodex(input)) score += 15;
        },
        .frontend => {
            if (isAntigravity(input)) score += 35;
            if (isClaude(input)) score += 15;
            if (isCodex(input)) score += 10;
        },
        .general => {
            if (isClaude(input)) score += 10;
            if (isCodex(input)) score += 10;
        },
    }
    if (isAntigravity(input)) score += 5;

    // Ledger-based reputation. Successes count mildly, failures count
    // heavily. The asymmetry reflects that a single failure is much more
    // informative than a single success.
    if (input.calls != 0) {
        score += @as(i64, @intCast(input.successes * 10));
        score -= @as(i64, @intCast(input.failures * 50));
        // Success rate bonus: an agent with a high success rate deserves
        // more than the raw count suggests.
        if (input.calls > 2 and input.successes * 3 >= input.calls * 2) score += 15;
        // Chronic failure: more than half of calls failing is a strong signal.
        if (input.calls > 2 and input.failures * 2 >= input.calls) score -= 25;
    }

    // Cooldown / rate-limit penalty. An agent in active cooldown should
    // only be selected when there is no alternative; the score reflects
    // that by going deeply negative.
    if (input.cooldown_until_ms > input.now_ms) {
        score -= 500;
    } else if (input.recent_rate_limits != 0) {
        // Recent but expired rate limits still lower confidence.
        score -= @as(i64, @intCast(input.recent_rate_limits)) * 20;
    }

    return score;
}

fn requiresFileEdits(kind: TaskKind) bool {
    return switch (kind) {
        .bugfix, .refactor, .frontend, .broad, .general, .test_fix => true,
        .terminal, .review => false,
    };
}

fn requiresCommands(kind: TaskKind) bool {
    return switch (kind) {
        .terminal, .test_fix, .bugfix => true,
        .refactor, .review, .frontend, .broad, .general => false,
    };
}

fn requiresReadOnly(kind: TaskKind) bool {
    return switch (kind) {
        .review, .broad => true,
        else => false,
    };
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

/// classifyTaskConfidence reports the chosen kind plus a low/medium/high
/// confidence label. High confidence means a specific keyword matched;
/// medium means a weaker synonym matched; low means no keyword matched
/// and we fell back to general. Callers use this to decide whether to
/// trust the local classifier or consult the subscription router.
pub const ClassifyConfidence = enum { low, medium, high };

pub const ClassifiedTask = struct {
    kind: TaskKind,
    confidence: ClassifyConfidence,
    matched_keyword: []const u8,
};

pub fn classifyTaskConfidence(text: []const u8) ClassifiedTask {
    // Order mirrors classifyTask: terminal > test > review > frontend >
    // refactor > bugfix > broad. Each row lists specific (high) then
    // weaker (medium) keywords. Japanese keywords are treated as
    // high-confidence because they are unambiguous within a JP context.
    if (matchKeyword(text, &.{
        "terminal", "shell", "command", "script", "cli",
        "ターミナル",
        "シェル",
        "コマンド",
        "スクリプト",
    })) |_| return .{ .kind = .terminal, .confidence = .high, .matched_keyword = "terminal" };
    if (matchKeyword(text, &.{
        "test", "spec", "failing", "failure", "flake", "flaky",
        "テスト",
        "失敗",
    })) |hit| return .{ .kind = .test_fix, .confidence = .high, .matched_keyword = hit };
    if (matchKeyword(text, &.{
        "review", "audit", "security", "vulnerab", "cve",
        "レビュー",
        "監査",
        "セキュリティ",
        "脆弱",
    })) |hit| return .{ .kind = .review, .confidence = .high, .matched_keyword = hit };
    if (matchKeyword(text, &.{
        "frontend", "ui", "ux", "layout", "css", "react", "vue", "svelte",
        "フロントエンド",
        "画面",
        "レイアウト",
        "デザイン",
    })) |hit| return .{ .kind = .frontend, .confidence = .high, .matched_keyword = hit };
    if (matchKeyword(text, &.{
        "refactor", "rename", "cleanup", "restructure", "modernize",
        "リファクタ",
        "リネーム",
        "整理",
        "再構成",
    })) |hit| return .{ .kind = .refactor, .confidence = .high, .matched_keyword = hit };
    if (matchKeyword(text, &.{
        "bug", "fix", "crash", "error", "broken", "wrong",
        "バグ",
        "修正",
        "エラー",
        "壊れ",
    })) |hit| return .{ .kind = .bugfix, .confidence = .high, .matched_keyword = hit };
    if (matchKeyword(text, &.{
        "broad", "architecture", "investigate", "unclear", "explore",
        "全体",
        "アーキテクチャ",
        "調査",
        "不明",
    })) |hit| return .{ .kind = .broad, .confidence = .high, .matched_keyword = hit };
    // No keyword hit: classify as general with low confidence so callers
    // can decide to consult the subscription router for a second opinion.
    return .{ .kind = .general, .confidence = .low, .matched_keyword = "" };
}

fn matchKeyword(text: []const u8, needles: []const []const u8) ?[]const u8 {
    for (needles) |needle| {
        if (containsIgnoreCase(text, needle)) return needle;
    }
    return null;
}

/// suggestAgent returns the agent id that the heuristic prefers for a
/// given kind, ignoring ledger reputation. Used by the CLI to show a
/// recommendation before probing real agents.
pub fn suggestAgent(kind: TaskKind) PreferredAgent {
    return switch (kind) {
        .test_fix, .terminal => .codex,
        .bugfix, .refactor, .review, .broad => .claude,
        .frontend => .antigravity,
        .general => .none,
    };
}

/// nearestCommand returns the closest known command name to `input`, or
/// null if nothing is close enough. Used by the TUI to show "did you
/// mean" suggestions for typos.
pub fn nearestCommand(input: []const u8, known: []const []const u8) ?[]const u8 {
    if (input.len == 0) return null;
    var best: []const u8 = "";
    var best_distance: usize = std.math.maxInt(usize);
    for (known) |candidate| {
        const distance = editDistance(input, candidate);
        // Accept a candidate only if it is within ~40% of the input length.
        // This avoids suggesting unrelated short commands for long typos.
        const threshold = @max(@as(usize, 2), (input.len + 1) / 3);
        if (distance <= threshold and distance < best_distance) {
            best_distance = distance;
            best = candidate;
        }
    }
    return if (best.len != 0) best else null;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    // Levenshtein with O(min(len)) memory. Good enough for short command
    // names; not called in hot paths.
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    var prev = std.heap.page_allocator.alloc(usize, b.len + 1) catch return std.math.maxInt(usize);
    defer std.heap.page_allocator.free(prev);
    var curr = std.heap.page_allocator.alloc(usize, b.len + 1) catch return std.math.maxInt(usize);
    defer std.heap.page_allocator.free(curr);
    for (0..b.len + 1) |j| prev[j] = j;
    for (0..a.len) |i| {
        curr[0] = i + 1;
        for (0..b.len) |j| {
            const cost: usize = if (std.ascii.toLower(a[i]) == std.ascii.toLower(b[j])) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        std.mem.swap([]usize, &prev, &curr);
    }
    return prev[b.len];
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
    if (std.mem.eql(u8, value, "frontend")) return .frontend;
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
