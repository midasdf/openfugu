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
