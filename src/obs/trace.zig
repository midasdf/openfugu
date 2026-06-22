const std = @import("std");
const types = @import("../core/types.zig");

pub const Event = struct {
    turn: u32,
    depth: u32,
    node: []const u8,
    agent: []const u8,
    role: types.Role,
    intent: types.Intent,
    planner: []const u8,
    verification: []const u8,
    accepted: bool,
};

pub fn line(allocator: std.mem.Allocator, event: Event) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "turn={d} depth={d} node={s} agent={s} role={s} intent={s} planner={s} verification={s} accepted={}\n",
        .{
            event.turn,
            event.depth,
            event.node,
            event.agent,
            @tagName(event.role),
            @tagName(event.intent),
            event.planner,
            event.verification,
            event.accepted,
        },
    );
}
