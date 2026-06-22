const std = @import("std");
const types = @import("core/types.zig");

pub const version = "0.1.0";

pub const UnknownAuthPolicy = enum {
    disable,
    allow,
};

pub const SubscriptionConfig = struct {
    only: bool = true,
    reject_api_key_auth: bool = true,
    strip_known_api_key_env: bool = true,
    unknown_auth: UnknownAuthPolicy = .disable,
};

pub const Config = struct {
    subscription: SubscriptionConfig = .{},

    pub fn default() Config {
        return .{};
    }
};

pub fn authAllowed(subscription: SubscriptionConfig, auth: types.AuthKind) bool {
    if (!subscription.only) return auth != .unauthenticated;

    return switch (auth) {
        .subscription, .organization_subscription => true,
        .api_key => !subscription.reject_api_key_auth,
        .unauthenticated => false,
        .unknown => subscription.unknown_auth == .allow,
    };
}

pub fn redactKnownSecrets(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, input, ' ');
    var first = true;
    while (it.next()) |part| {
        if (!first) try out.append(allocator, ' ');
        first = false;

        if (std.mem.indexOf(u8, part, "API_KEY=")) |idx| {
            try out.appendSlice(allocator, part[0 .. idx + "API_KEY=".len]);
            try out.appendSlice(allocator, "[redacted]");
        } else {
            try out.appendSlice(allocator, part);
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn validateText(text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r,{}.");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;

        const key = keyPart(line);
        if (key.len == 0) continue;
        if (!isKnownField(key)) return error.UnknownField;
    }
}

pub fn validateTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    validateText(text) catch |err| {
        if (err != error.UnknownField) return err;
        return std.fmt.allocPrint(allocator, "unknown config field: {s}", .{firstUnknownField(text)});
    };
    return allocator.dupe(u8, "ok");
}

fn keyPart(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '=')) |idx| return std.mem.trim(u8, line[0..idx], " \t.");
    return "";
}

fn firstUnknownField(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r,{}.");
        const key = keyPart(line);
        if (key.len != 0 and !isKnownField(key)) return key;
    }
    return "";
}

fn isKnownField(key: []const u8) bool {
    const known = [_][]const u8{
        "subscription.only",
        "subscription",
        "subscription.reject_api_key_auth",
        "subscription.strip_known_api_key_env",
        "subscription.unknown_auth",
        "agents",
        "provider_overage",
        "claude",
        "agents.claude.cmd",
        "agents.claude.enabled",
        "agents.claude.weight",
        "agents.claude.max_parallel",
        "codex",
        "agents.codex.cmd",
        "agents.codex.enabled",
        "agents.codex.weight",
        "agents.codex.max_parallel",
        "antigravity",
        "agents.antigravity.cmd",
        "agents.antigravity.enabled",
        "agents.antigravity.weight",
        "agents.antigravity.max_parallel",
        "planner",
        "planner.backend",
        "backend",
        "mode",
        "budget",
        "budget.max_turns",
        "budget.max_depth",
        "verification",
        "commands",
        "name",
        "argv",
        "verification.require_at_least_one_command",
        "workspace",
        "workspace.root",
        "workspace.require_clean_source",
        "workspace.auto_commit",
        "logging",
        "logging.include_content",
        "logging.max_stream_bytes",
        "logging.max_line_bytes",
        "only",
        "reject_api_key_auth",
        "strip_known_api_key_env",
        "unknown_auth",
    };
    for (known) |item| if (std.mem.eql(u8, key, item)) return true;
    return false;
}
