const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return 2;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = args[2] });
    return 0;
}
