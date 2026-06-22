const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    var err_buf: [256]u8 = undefined;
    var err = std.Io.File.stderr().writer(init.io, &err_buf);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--version")) {
        try out.interface.writeAll("supported-1\n");
        try out.interface.flush();
        return 0;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "auth")) {
        try out.interface.writeAll("auth=subscription login=ok\n");
        try out.interface.flush();
        return 0;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "apikey")) {
        try out.interface.writeAll("auth=api_key\n");
        try out.interface.flush();
        return 0;
    }

    try err.interface.writeAll("unknown probe command\n");
    try err.interface.flush();
    return 2;
}
