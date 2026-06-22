const std = @import("std");
const adapter = @import("adapter.zig");
const config = @import("../config.zig");
const types = @import("../core/types.zig");
const runner = @import("../proc/runner.zig");

pub const AgentReport = struct {
    name: []const u8,
    compatibility: types.Compatibility,
    auth: types.AuthKind,
    runnable: bool,
    exists: bool = false,
    version: []const u8 = "",
    owns_version: bool = false,
    non_interactive: bool = false,
    structured_output: bool = false,
    overage_known: bool = false,

    pub fn deinit(self: *AgentReport, allocator: std.mem.Allocator) void {
        if (self.owns_version) allocator.free(self.version);
        self.* = undefined;
    }
};

pub fn freeReports(allocator: std.mem.Allocator, reports: []AgentReport) void {
    for (reports) |*agent| agent.deinit(allocator);
    allocator.free(reports);
}

pub fn report(name: []const u8, profile: adapter.Profile, auth: types.AuthKind, is_runnable: bool) AgentReport {
    return .{
        .name = name,
        .compatibility = profile.compatibility,
        .auth = auth,
        .runnable = is_runnable,
    };
}

pub const DetectSpec = struct {
    name: []const u8,
    version_argv: []const []const u8,
    auth_argv: []const []const u8,
    task_argv: ?[]const []const u8 = null,
    supported_version: []const u8,
    profile: adapter.Profile,
    subscription: config.SubscriptionConfig,
};

pub fn detect(allocator: std.mem.Allocator, io: std.Io, spec: DetectSpec) !AgentReport {
    var version_result = runner.run(allocator, io, .{
        .executable = spec.version_argv[0],
        .argv = spec.version_argv,
        .cwd = ".",
        .stdout_tail_bytes = 2048,
        .stderr_tail_bytes = 2048,
        .timeout_ms = 5000,
    }) catch return missing(spec.name);
    defer version_result.deinit(allocator);

    if (version_result.exit_code != 0) return missing(spec.name);

    const version = std.mem.trim(u8, version_result.stdout_tail, " \n\r\t");
    var auth_result = try runner.run(allocator, io, .{
        .executable = spec.auth_argv[0],
        .argv = spec.auth_argv,
        .cwd = ".",
        .stdout_tail_bytes = 2048,
        .stderr_tail_bytes = 2048,
        .timeout_ms = 5000,
    });
    defer auth_result.deinit(allocator);

    const auth = if (auth_result.exit_code == 0) classifyAuth(auth_result.stdout_tail, auth_result.stderr_tail) else .unknown;
    const compatibility: types.Compatibility = if (std.mem.startsWith(u8, version, spec.supported_version))
        spec.profile.compatibility
    else
        .unknown;
    const effective_profile = adapter.Profile{
        .name = spec.profile.name,
        .compatibility = compatibility,
        .capability = spec.profile.capability,
        .auth_check_argv = spec.profile.auth_check_argv,
        .known_api_key_env = spec.profile.known_api_key_env,
    };

    return .{
        .name = spec.name,
        .compatibility = compatibility,
        .auth = auth,
        .runnable = adapter.runnable(spec.subscription, effective_profile, auth),
        .exists = true,
        .version = try allocator.dupe(u8, version),
        .owns_version = true,
        .non_interactive = compatibility == .supported or compatibility == .degraded,
        .structured_output = spec.profile.capability.structured_output and compatibility == .supported,
        .overage_known = false,
    };
}

fn missing(name: []const u8) AgentReport {
    return .{
        .name = name,
        .compatibility = .unknown,
        .auth = .unknown,
        .runnable = false,
        .exists = false,
    };
}

fn classifyAuth(stdout: []const u8, stderr: []const u8) types.AuthKind {
    if (hasAuthText(stdout, "api_key") or hasAuthText(stderr, "api_key")) return .api_key;
    if (hasAuthText(stdout, "organization_subscription") or hasAuthText(stderr, "organization_subscription")) return .organization_subscription;
    if (hasAuthText(stdout, "subscription") or hasAuthText(stderr, "subscription")) return .subscription;
    if (hasAuthText(stdout, "Logged in using ChatGPT") or hasAuthText(stderr, "Logged in using ChatGPT")) return .subscription;
    if (hasAuthText(stdout, "unauthenticated") or hasAuthText(stderr, "unauthenticated")) return .unauthenticated;
    return .unknown;
}

fn hasAuthText(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}
