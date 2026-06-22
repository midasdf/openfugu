const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var in_buf: [256]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    const input = try reader.interface.allocRemaining(init.arena.allocator(), .limited(4096));

    var out_buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    try out.interface.writeAll(input);
    try out.interface.flush();
}
