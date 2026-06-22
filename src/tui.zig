const std = @import("std");
const zz = @import("zigzag");

pub fn render(allocator: std.mem.Allocator, status: []const u8, input: []const u8, output: []const u8) ![]u8 {
    return renderSized(allocator, status, input, output, 90, 24);
}

pub fn renderSized(allocator: std.mem.Allocator, status: []const u8, input: []const u8, output: []const u8, width: u16, height: u16) ![]u8 {
    const frame_width: u16 = @max(40, width -| 2);
    const inner_width: u16 = @max(20, frame_width -| 4);
    const viewport_height: u16 = @max(4, height -| 10);
    var viewport = zz.Viewport.init(allocator, inner_width, viewport_height);
    defer viewport.deinit();
    viewport.setWrap(true);
    viewport.gotoBottom();
    try viewport.setContent(output);
    viewport.gotoBottom();
    const output_view = try viewport.view(allocator);
    defer allocator.free(output_view);

    const body = try std.fmt.allocPrint(allocator,
        \\openfugu
        \\status: {s}
        \\
        \\{s}
        \\
        \\> {s}
        \\
        \\{s}
    , .{ status, output_view, input, ":help  :doctor  :agents  :dry-run  :clear  :quit" });
    defer allocator.free(body);

    const frame = (zz.Style{})
        .borderAll(zz.Border.ascii)
        .borderForeground(.cyan)
        .paddingAll(1)
        .width(frame_width);
    const framed = try frame.render(allocator, body);
    defer allocator.free(framed);

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ zz.ansi.screen_clear, zz.ansi.cursor_home, framed });
}
