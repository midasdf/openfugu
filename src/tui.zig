const std = @import("std");
const zz = @import("zigzag");

pub fn render(allocator: std.mem.Allocator, status: []const u8, input: []const u8, output: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(allocator,
        \\openfugu
        \\status: {s}
        \\
        \\{s}
        \\
        \\> {s}
        \\
        \\{s}
    , .{ status, output, input, ":quit / :exit to leave" });
    defer allocator.free(body);

    const frame = (zz.Style{})
        .borderAll(zz.Border.ascii)
        .borderForeground(.cyan)
        .paddingAll(1)
        .width(90);
    const framed = try frame.render(allocator, body);
    defer allocator.free(framed);

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ zz.ansi.screen_clear, zz.ansi.cursor_home, framed });
}
