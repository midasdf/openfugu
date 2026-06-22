const std = @import("std");
const openfugu = @import("openfugu");

pub fn main() !void {
    std.debug.print("openfugu {s}\n", .{openfugu.config.version});
}
