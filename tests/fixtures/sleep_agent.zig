const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try out.interface.writeAll("sleeping\n");
    try out.interface.flush();
    try init.io.sleep(std.Io.Duration.fromSeconds(5), .awake);
}
