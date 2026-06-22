const adapter = @import("adapter.zig");
const types = @import("../core/types.zig");

pub const AgentReport = struct {
    name: []const u8,
    compatibility: types.Compatibility,
    auth: types.AuthKind,
    runnable: bool,
};

pub fn report(name: []const u8, profile: adapter.Profile, auth: types.AuthKind, is_runnable: bool) AgentReport {
    return .{
        .name = name,
        .compatibility = profile.compatibility,
        .auth = auth,
        .runnable = is_runnable,
    };
}
