const std = @import("std");

pub fn fixture(allocator: std.mem.Allocator, run_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "replay run={s} event=fixture no-child-process-reexecuted\n", .{run_id});
}
