const std = @import("std");

pub fn line(allocator: std.mem.Allocator, turn: u32, node: []const u8, accepted: bool) ![]u8 {
    return std.fmt.allocPrint(allocator, "turn={d} node={s} accepted={}\n", .{ turn, node, accepted });
}
