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
    var dry_run = false;

    while (true) {
        const status = if (dry_run) "ready dry-run" else "ready apply";
        if (fullscreen) {
            const screen = try openfugu.tui.render(init.gpa, status, "", last_output);
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
            .clear => {
                init.gpa.free(last_output);
                last_output = try init.gpa.dupe(u8, "Cleared.\n");
                if (!fullscreen) try writer.interface.writeAll(last_output);
            },
            .help => {
                try replaceLog(init.gpa, &last_output,
                    \\Commands:
                    \\  :doctor  show agent health
                    \\  :agents  list runnable agents
                    \\  :dry-run toggle dry-run mode
                    \\  :clear   clear this session
                    \\  :quit    exit
                    \\
                    \\Type any other line to route and execute it.
                    \\
                );
                if (!fullscreen) try writer.interface.writeAll(last_output);
            },
            .doctor => {
                try runInteractiveCommand(init, &last_output, &.{ "openfugu", "doctor" }, ":doctor");
                if (!fullscreen) try writer.interface.writeAll(last_output);
            },
            .agents => {
                try runInteractiveCommand(init, &last_output, &.{ "openfugu", "agents" }, ":agents");
                if (!fullscreen) try writer.interface.writeAll(last_output);
            },
            .dry_run => {
                dry_run = !dry_run;
                init.gpa.free(last_output);
                last_output = try std.fmt.allocPrint(init.gpa, "dry-run={}\n", .{dry_run});
                if (!fullscreen) try writer.interface.writeAll(last_output);
            },
            .task => |task| {
                if (fullscreen) {
                    const screen = try openfugu.tui.render(init.gpa, if (dry_run) "running dry-run" else "running apply", task, last_output);
                    defer init.gpa.free(screen);
                    try writer.interface.writeAll(screen);
                    try writer.interface.flush();
                }
                const apply_args = [_][]const u8{ "openfugu", "--explain-routing", task };
                const dry_args = [_][]const u8{ "openfugu", "--no-apply", "--explain-routing", task };
                var result = openfugu.cli.runWithIo(init.gpa, init.io, if (dry_run) &dry_args else &apply_args) catch |err| switch (err) {
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
                try appendLog(init.gpa, &last_output, task, result.text);
                if (!fullscreen) try writer.interface.writeAll(result.text);
            },
        }
    }
    return openfugu.cli.exit_ok;
}

fn runInteractiveCommand(init: std.process.Init, log: *[]u8, args: []const []const u8, label: []const u8) !void {
    var result = openfugu.cli.runWithIo(init.gpa, init.io, args) catch |err| {
        const text = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
        defer init.gpa.free(text);
        try appendLog(init.gpa, log, label, text);
        return;
    };
    defer result.deinit(init.gpa);
    try appendLog(init.gpa, log, label, result.text);
}

fn replaceLog(allocator: std.mem.Allocator, log: *[]u8, text: []const u8) !void {
    allocator.free(log.*);
    log.* = try allocator.dupe(u8, text);
}

fn appendLog(allocator: std.mem.Allocator, log: *[]u8, input: []const u8, output: []const u8) !void {
    const joined = try std.fmt.allocPrint(allocator, "{s}\n> {s}\n{s}", .{ log.*, input, output });
    allocator.free(log.*);
    log.* = if (joined.len > 64 * 1024) try allocator.dupe(u8, joined[joined.len - 64 * 1024 ..]) else joined;
    if (joined.ptr != log.*.ptr) allocator.free(joined);
}
