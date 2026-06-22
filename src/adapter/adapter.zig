const std = @import("std");
const config = @import("../config.zig");
const types = @import("../core/types.zig");

pub const Profile = struct {
    name: []const u8,
    compatibility: types.Compatibility,
    capability: types.Capability,
    auth_check_argv: []const []const u8,
    known_api_key_env: []const []const u8,
};

pub const ProfileKind = enum {
    supported_1,
    degraded_text,
    unknown,
};

pub const OwnedInvocation = struct {
    value: types.Invocation,

    pub fn deinit(self: *OwnedInvocation, allocator: std.mem.Allocator) void {
        allocator.free(self.value.argv);
        self.* = undefined;
    }
};

pub fn runnable(subscription: config.SubscriptionConfig, profile: Profile, auth: types.AuthKind) bool {
    if (profile.compatibility != .supported and profile.compatibility != .degraded) return false;
    return config.authAllowed(subscription, auth);
}

pub fn readMode(role: types.Role) []const u8 {
    return switch (role) {
        .thinker, .verifier => "read-only",
        .worker => "workspace-write",
    };
}

pub fn ownInvocation(allocator: std.mem.Allocator, invocation: types.Invocation) !OwnedInvocation {
    return .{ .value = .{
        .executable = invocation.executable,
        .argv = try allocator.dupe([]const u8, invocation.argv),
        .cwd = invocation.cwd,
        .stdin = invocation.stdin,
        .env_policy = invocation.env_policy,
        .transport = invocation.transport,
        .output_format = invocation.output_format,
    } };
}
