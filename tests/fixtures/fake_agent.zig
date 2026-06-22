const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out_buf: [128]u8 = undefined;
    var err_buf: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    var err = std.Io.File.stderr().writer(io, &err_buf);
    try out.interface.writeAll("fake out\n");
    try err.interface.writeAll("fake err\n");
    try out.interface.flush();
    try err.interface.flush();
}
