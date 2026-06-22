const std = @import("std");
const openfugu = @import("openfugu");

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

    try writer.interface.writeAll("openfugu TUI\n:type a task, :quit to exit\n");
    while (true) {
        try writer.interface.writeAll("openfugu> ");
        try writer.interface.flush();

        const line = try reader.interface.takeDelimiter('\n') orelse break;
        switch (openfugu.cli.interactiveInput(line)) {
            .empty => continue,
            .quit => break,
            .task => |task| {
                const run_args = [_][]const u8{ "openfugu", "--explain-routing", task };
                var result = openfugu.cli.runWithIo(init.gpa, init.io, &run_args) catch |err| switch (err) {
                    error.InvalidArgs => {
                        try writer.interface.writeAll("usage error\n");
                        continue;
                    },
                    else => {
                        try writer.interface.print("error: {s}\n", .{@errorName(err)});
                        continue;
                    },
                };
                defer result.deinit(init.gpa);
                try writer.interface.writeAll(result.text);
                try writer.interface.flush();
            },
        }
    }
    return openfugu.cli.exit_ok;
}
