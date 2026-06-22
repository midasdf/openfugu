const std = @import("std");
const zz = @import("zigzag");

pub const Dashboard = struct {
    status: []const u8,
    input: []const u8,
    output: []const u8,
    agents: []const u8,
    history: []const u8,
};

pub fn render(allocator: std.mem.Allocator, status: []const u8, input: []const u8, output: []const u8) ![]u8 {
    return renderSized(allocator, status, input, output, 90, 24);
}

pub fn renderSized(allocator: std.mem.Allocator, status: []const u8, input: []const u8, output: []const u8, width: u16, height: u16) ![]u8 {
    return renderDashboardSized(allocator, .{
        .status = status,
        .input = input,
        .output = output,
        .agents = ":agents to refresh\n",
        .history = "No tasks yet.\n",
    }, width, height);
}

pub fn renderDashboardSized(allocator: std.mem.Allocator, dashboard: Dashboard, width: u16, height: u16) ![]u8 {
    const frame_width: u16 = @max(40, width -| 2);
    const inner_width: u16 = @max(20, frame_width -| 6);
    const side_width: u16 = @min(@as(u16, 28), @max(@as(u16, 18), inner_width / 3));
    const main_width: u16 = @max(@as(u16, 20), inner_width -| side_width -| 2);
    const output_height: u16 = @max(4, height -| 12);

    const output_view = try viewportText(allocator, dashboard.output, main_width, output_height, true);
    defer allocator.free(output_view);
    const agents_view = try viewportText(allocator, dashboard.agents, side_width, @max(@as(u16, 3), output_height / 2), false);
    defer allocator.free(agents_view);
    const history_view = try viewportText(allocator, dashboard.history, side_width, @max(@as(u16, 3), output_height -| (output_height / 2)), true);
    defer allocator.free(history_view);
    const side = try std.fmt.allocPrint(allocator, "Agents\n{s}\nHistory\n{s}", .{ agents_view, history_view });
    defer allocator.free(side);

    const body = try std.fmt.allocPrint(allocator,
        \\openfugu
        \\status: {s}
        \\
        \\{s}
        \\
        \\{s}
        \\
        \\> {s}
        \\
        \\{s}
    , .{ dashboard.status, side, output_view, dashboard.input, "Tab suggest  Up/Down history  :help commands  Esc quit" });
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

fn viewportText(allocator: std.mem.Allocator, text: []const u8, width: u16, height: u16, bottom: bool) ![]const u8 {
    var viewport = zz.Viewport.init(allocator, width, height);
    defer viewport.deinit();
    viewport.setWrap(true);
    try viewport.setContent(text);
    if (bottom) viewport.gotoBottom();
    return viewport.view(allocator);
}
