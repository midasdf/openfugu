const std = @import("std");
const openfugu = @import("openfugu");
const zz = @import("zigzag");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len <= 1) return repl(init);

    var result = openfugu.cli.runWithIo(init.gpa, init.io, args) catch |err| switch (err) {
        error.InvalidArgs => return openfugu.cli.exit_usage,
        else => return openfugu.cli.exit_planner,
    };
    defer result.deinit(init.gpa);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    try writer.interface.writeAll(result.text);
    try writer.interface.flush();
    return result.code;
}

fn repl(init: std.process.Init) !u8 {
    var in_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    var writer = std.Io.File.stdout().writer(init.io, &out_buf);
    const fullscreen = std.Io.File.stdout().isTty(init.io) catch false;

    if (fullscreen) try writer.interface.writeAll(zz.ansi.alt_screen_enter ++ zz.ansi.cursor_hide);
    defer if (fullscreen) {
        writer.interface.writeAll(zz.ansi.cursor_show ++ zz.ansi.alt_screen_exit) catch {};
        writer.interface.flush() catch {};
    };

    var last_output = try init.gpa.dupe(u8, "Type a task and press Enter.\n");
    defer init.gpa.free(last_output);

    while (true) {
        if (fullscreen) {
            const screen = try openfugu.tui.render(init.gpa, "ready", "", last_output);
            defer init.gpa.free(screen);
            try writer.interface.writeAll(screen);
        } else {
            try writer.interface.writeAll("openfugu TUI\n:type a task, :quit to exit\nopenfugu> ");
        }
        try writer.interface.flush();

        const line = try reader.interface.takeDelimiter('\n') orelse break;
        switch (openfugu.cli.interactiveInput(line)) {
            .empty => continue,
            .quit => break,
            .task => |task| {
                if (fullscreen) {
                    const screen = try openfugu.tui.render(init.gpa, "running", task, last_output);
                    defer init.gpa.free(screen);
                    try writer.interface.writeAll(screen);
                    try writer.interface.flush();
                }
                const run_args = [_][]const u8{ "openfugu", "--explain-routing", task };
                var result = openfugu.cli.runWithIo(init.gpa, init.io, &run_args) catch |err| switch (err) {
                    error.InvalidArgs => {
                        init.gpa.free(last_output);
                        last_output = try init.gpa.dupe(u8, "usage error\n");
                        continue;
                    },
                    else => {
                        init.gpa.free(last_output);
                        last_output = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
                        continue;
                    },
                };
                defer result.deinit(init.gpa);
                init.gpa.free(last_output);
                last_output = try init.gpa.dupe(u8, result.text);
                if (!fullscreen) try writer.interface.writeAll(result.text);
            },
        }
    }
    return openfugu.cli.exit_ok;
}
