const std = @import("std");
const openfugu = @import("openfugu");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out = openfugu.cli.runAlloc(init.gpa, args) catch |err| switch (err) {
        error.InvalidArgs => return openfugu.cli.exit_usage,
        else => return openfugu.cli.exit_planner,
    };
    defer init.gpa.free(out);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    try writer.interface.writeAll(out);
    try writer.interface.flush();
    return openfugu.cli.exit_ok;
}
