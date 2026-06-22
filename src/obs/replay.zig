const std = @import("std");

pub fn fixture(allocator: std.mem.Allocator, run_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "replay run={s} event=fixture no-child-process-reexecuted\n", .{run_id});
}

pub fn renderLedgerText(allocator: std.mem.Allocator, run_id: []const u8, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, run_id) == null) continue;
        try out.print(allocator, "replay run={s} event={s} no-child-process-reexecuted\n", .{ run_id, line });
    }
    if (out.items.len == 0) try out.print(allocator, "replay run={s} event=missing no-child-process-reexecuted\n", .{run_id});
    return out.toOwnedSlice(allocator);
}
