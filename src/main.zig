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
    const fullscreen = (std.Io.File.stdin().isTty(init.io) catch false) and
        (std.Io.File.stdout().isTty(init.io) catch false);
    if (fullscreen) return rawRepl(init);

    var in_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    var writer = std.Io.File.stdout().writer(init.io, &out_buf);

    var last_output = try init.gpa.dupe(u8, "Type a task and press Enter.\n");
    defer init.gpa.free(last_output);
    var agents = try init.gpa.dupe(u8, ":agents to refresh\n");
    defer init.gpa.free(agents);
    var history = try init.gpa.dupe(u8, "No tasks yet.\n");
    defer init.gpa.free(history);
    var dry_run = false;
    var agent_filter: ?[]u8 = null;
    defer if (agent_filter) |value| init.gpa.free(value);
    var mode = try init.gpa.dupe(u8, "auto");
    defer init.gpa.free(mode);
    var planner = try init.gpa.dupe(u8, "heuristic");
    defer init.gpa.free(planner);

    while (true) {
        const status = try std.fmt.allocPrint(init.gpa, "{s} agent={s} mode={s} planner={s}", .{
            if (dry_run) "ready dry-run" else "ready apply",
            agent_filter orelse "auto",
            mode,
            planner,
        });
        defer init.gpa.free(status);
        try writer.interface.writeAll("openfugu TUI\n:type a task, :quit to exit\nopenfugu> ");
        try writer.interface.flush();

        const line = try reader.interface.takeDelimiter('\n') orelse break;
        switch (openfugu.cli.interactiveInput(line)) {
            .empty => continue,
            .quit => break,
            .clear => {
                init.gpa.free(last_output);
                last_output = try init.gpa.dupe(u8, "Cleared.\n");
                try writer.interface.writeAll(last_output);
            },
            .help => {
                try replaceLog(init.gpa, &last_output,
                    \\Commands:
                    \\  :doctor  show agent health
                    \\  :agents  list runnable agents
                    \\  :dry-run toggle dry-run mode
                    \\  :agent   set agent: auto, claude, codex, agy
                    \\  :mode    set mode: auto, single, race, ensemble
                    \\  :planner set planner: heuristic, subscription-agent
                    \\  :clear   clear this session
                    \\  :quit    exit
                    \\
                    \\Type any other line to route and execute it.
                    \\
                );
                try writer.interface.writeAll(last_output);
            },
            .doctor => {
                try runInteractiveCommand(init, &last_output, &.{ "openfugu", "doctor" }, ":doctor");
                try writer.interface.writeAll(last_output);
            },
            .agents => {
                const agent_text = try runCommandText(init, &.{ "openfugu", "agents" });
                defer init.gpa.free(agent_text);
                try replaceLog(init.gpa, &agents, agent_text);
                try appendLog(init.gpa, &last_output, ":agents", agent_text);
                try writer.interface.writeAll(last_output);
            },
            .dry_run => {
                dry_run = !dry_run;
                init.gpa.free(last_output);
                last_output = try std.fmt.allocPrint(init.gpa, "dry-run={}\n", .{dry_run});
                try writer.interface.writeAll(last_output);
            },
            .agent => |value| {
                if (!validAgent(value)) {
                    try replaceLog(init.gpa, &last_output, "invalid agent\n");
                    continue;
                }
                if (agent_filter) |old| init.gpa.free(old);
                agent_filter = if (std.mem.eql(u8, value, "auto")) null else try init.gpa.dupe(u8, value);
                try replaceLog(init.gpa, &last_output, "agent updated\n");
                try writer.interface.writeAll(last_output);
            },
            .mode => |value| {
                if (!validMode(value)) {
                    try replaceLog(init.gpa, &last_output, "invalid mode\n");
                    continue;
                }
                init.gpa.free(mode);
                mode = try init.gpa.dupe(u8, value);
                try replaceLog(init.gpa, &last_output, "mode updated\n");
                try writer.interface.writeAll(last_output);
            },
            .planner => |value| {
                if (!validPlanner(value)) {
                    try replaceLog(init.gpa, &last_output, "invalid planner\n");
                    continue;
                }
                init.gpa.free(planner);
                planner = try init.gpa.dupe(u8, value);
                try replaceLog(init.gpa, &last_output, "planner updated\n");
                try writer.interface.writeAll(last_output);
            },
            .task => |task| {
                try appendHistory(init.gpa, &history, task);
                var args = std.array_list.Managed([]const u8).init(init.gpa);
                defer args.deinit();
                try args.append("openfugu");
                if (dry_run) try args.append("--no-apply");
                try args.append("--explain-routing");
                if (agent_filter) |agent| {
                    try args.append("--agents");
                    try args.append(agent);
                }
                if (!std.mem.eql(u8, mode, "auto")) {
                    try args.append("--mode");
                    try args.append(mode);
                }
                if (!std.mem.eql(u8, planner, "heuristic")) {
                    try args.append("--planner");
                    try args.append(planner);
                }
                try args.append(task);
                var result = openfugu.cli.runWithIo(init.gpa, init.io, args.items) catch |err| switch (err) {
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
                try writer.interface.writeAll(result.text);
            },
        }
    }
    return openfugu.cli.exit_ok;
}

fn rawRepl(init: std.process.Init) !u8 {
    var env = zz.Environment.fromEnvMap(init.environ_map);
    var term = try zz.Terminal.init(init.io, &env, .{ .alt_screen = true, .hide_cursor = false, .bracketed_paste = true });
    defer term.deinit();

    var input = zz.components.TextInput.init(init.gpa);
    defer input.deinit();
    input.setPlaceholder("type a task or :help");
    input.setCharLimit(4096);
    input.setSuggestions(&.{
        ":help",
        ":doctor",
        ":agents",
        ":dry-run",
        ":agent auto",
        ":agent claude",
        ":agent codex",
        ":agent agy",
        ":mode auto",
        ":mode single",
        ":mode race",
        ":mode ensemble",
        ":planner heuristic",
        ":planner subscription-agent",
        ":clear",
        ":quit",
    });

    var last_output = try init.gpa.dupe(u8, "Type a task and press Enter.\n");
    defer init.gpa.free(last_output);
    var agents = try init.gpa.dupe(u8, ":agents to refresh\n");
    defer init.gpa.free(agents);
    var history = try init.gpa.dupe(u8, "No tasks yet.\n");
    defer init.gpa.free(history);
    var last_task: ?[]u8 = null;
    defer if (last_task) |value| init.gpa.free(value);
    var dry_run = false;
    var agent_filter: ?[]u8 = null;
    defer if (agent_filter) |value| init.gpa.free(value);
    var mode = try init.gpa.dupe(u8, "auto");
    defer init.gpa.free(mode);
    var planner = try init.gpa.dupe(u8, "heuristic");
    defer init.gpa.free(planner);
    // ponytail: one foreground task; add a queue/cancel path when parallel TUI work matters.
    var job: ?*TaskJob = null;
    defer if (job) |running_job| finishJob(init.gpa, running_job);

    while (true) {
        if (job) |running_job| {
            if (running_job.done.load(.acquire)) {
                finishCompletedJob(init.gpa, running_job, &last_output) catch |err| {
                    init.gpa.free(last_output);
                    last_output = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
                };
                job = null;
            }
        }

        const input_view = try input.view(init.gpa);
        defer init.gpa.free(input_view);
        try drawRaw(init, &term, input_view, last_output, agents, history, dry_run, agent_filter, mode, planner, job != null);

        var input_buf: [256]u8 = undefined;
        const read = try term.readInput(&input_buf, if (job == null) -1 else 100);
        if (read == 0) continue;
        const events = try zz.input.keyboard.parseAll(init.gpa, input_buf[0..read]);
        defer init.gpa.free(events);
        for (events) |event| {
            if (event != .key) continue;
            const key = event.key;
            if (key.modifiers.ctrl and key.key == .char and key.key.char == 'c') return openfugu.cli.exit_ok;
            switch (key.key) {
                .escape => return openfugu.cli.exit_ok,
                .up => {
                    if (last_task) |task| try input.setValue(task);
                },
                .enter => {
                    const line = try init.gpa.dupe(u8, input.getValue());
                    defer init.gpa.free(line);
                    try input.setValue("");
                    switch (openfugu.cli.interactiveInput(line)) {
                        .task => {
                            if (last_task) |old| init.gpa.free(old);
                            last_task = try init.gpa.dupe(u8, std.mem.trim(u8, line, " \t\r\n"));
                        },
                        else => {},
                    }
                    const should_quit = try handleInteractiveLine(init, line, &last_output, &agents, &history, &dry_run, &agent_filter, &mode, &planner, &term, &job);
                    if (should_quit) return openfugu.cli.exit_ok;
                },
                else => input.handleKey(key),
            }
        }
    }
}

const TaskJob = struct {
    thread: std.Thread,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    argv: [][]const u8,
    label: []u8,
    text: ?[]u8 = null,
    code: u8 = openfugu.cli.exit_planner,

    fn deinit(self: *TaskJob, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        allocator.free(self.label);
        if (self.text) |text| std.heap.page_allocator.free(text);
        allocator.destroy(self);
    }
};

fn drawRaw(
    init: std.process.Init,
    term: *zz.Terminal,
    input: []const u8,
    output: []const u8,
    agents: []const u8,
    history: []const u8,
    dry_run: bool,
    agent_filter: ?[]const u8,
    mode: []const u8,
    planner: []const u8,
    running: bool,
) !void {
    const size = term.getSize() catch null;
    const fallback_size = tuiSize(init.environ_map);
    const width = if (size) |value| value.cols else fallback_size.width;
    const height = if (size) |value| value.rows else fallback_size.height;
    const status = try std.fmt.allocPrint(init.gpa, "{s} agent={s} mode={s} planner={s}", .{
        if (running) (if (dry_run) "running dry-run" else "running apply") else (if (dry_run) "ready dry-run" else "ready apply"),
        agent_filter orelse "auto",
        mode,
        planner,
    });
    defer init.gpa.free(status);
    const screen = try openfugu.tui.renderDashboardSized(init.gpa, .{
        .status = status,
        .input = input,
        .output = output,
        .agents = agents,
        .history = history,
    }, width, height);
    defer init.gpa.free(screen);
    try term.writer().writeAll(zz.ansi.screen_clear ++ zz.ansi.cursor_home);
    try term.writer().writeAll(screen);
    try term.flush();
}

fn handleInteractiveLine(
    init: std.process.Init,
    line: []const u8,
    last_output: *[]u8,
    agents: *[]u8,
    history: *[]u8,
    dry_run: *bool,
    agent_filter: *?[]u8,
    mode: *[]u8,
    planner: *[]u8,
    term: *zz.Terminal,
    job: *?*TaskJob,
) !bool {
    switch (openfugu.cli.interactiveInput(line)) {
        .empty => return false,
        .quit => return true,
        .clear => try replaceLog(init.gpa, last_output, "Cleared.\n"),
        .help => try replaceLog(init.gpa, last_output,
            \\Commands:
            \\  :doctor  show agent health
            \\  :agents  list runnable agents
            \\  :dry-run toggle dry-run mode
            \\  :agent   set agent: auto, claude, codex, agy
            \\  :mode    set mode: auto, single, race, ensemble
            \\  :planner set planner: heuristic, subscription-agent
            \\  :clear   clear this session
            \\  :quit    exit
            \\
            \\Type any other line to route and execute it.
            \\
        ),
        .doctor => try runInteractiveCommand(init, last_output, &.{ "openfugu", "doctor" }, ":doctor"),
        .agents => {
            const agent_text = try runCommandText(init, &.{ "openfugu", "agents" });
            defer init.gpa.free(agent_text);
            try replaceLog(init.gpa, agents, agent_text);
            try appendLog(init.gpa, last_output, ":agents", agent_text);
        },
        .dry_run => {
            dry_run.* = !dry_run.*;
            init.gpa.free(last_output.*);
            last_output.* = try std.fmt.allocPrint(init.gpa, "dry-run={}\n", .{dry_run.*});
        },
        .agent => |value| {
            if (!validAgent(value)) {
                try replaceLog(init.gpa, last_output, "invalid agent\n");
                return false;
            }
            if (agent_filter.*) |old| init.gpa.free(old);
            agent_filter.* = if (std.mem.eql(u8, value, "auto")) null else try init.gpa.dupe(u8, value);
            try replaceLog(init.gpa, last_output, "agent updated\n");
        },
        .mode => |value| {
            if (!validMode(value)) {
                try replaceLog(init.gpa, last_output, "invalid mode\n");
                return false;
            }
            init.gpa.free(mode.*);
            mode.* = try init.gpa.dupe(u8, value);
            try replaceLog(init.gpa, last_output, "mode updated\n");
        },
        .planner => |value| {
            if (!validPlanner(value)) {
                try replaceLog(init.gpa, last_output, "invalid planner\n");
                return false;
            }
            init.gpa.free(planner.*);
            planner.* = try init.gpa.dupe(u8, value);
            try replaceLog(init.gpa, last_output, "planner updated\n");
        },
        .task => |task| {
            if (job.* != null) {
                try replaceLog(init.gpa, last_output, "task already running\n");
                return false;
            }
            try appendHistory(init.gpa, history, task);
            try drawRaw(init, term, task, last_output.*, agents.*, history.*, dry_run.*, agent_filter.*, mode.*, planner.*, true);
            var args = std.array_list.Managed([]const u8).init(init.gpa);
            defer args.deinit();
            try args.append("openfugu");
            if (dry_run.*) try args.append("--no-apply");
            try args.append("--explain-routing");
            if (agent_filter.*) |agent| {
                try args.append("--agents");
                try args.append(agent);
            }
            if (!std.mem.eql(u8, mode.*, "auto")) {
                try args.append("--mode");
                try args.append(mode.*);
            }
            if (!std.mem.eql(u8, planner.*, "heuristic")) {
                try args.append("--planner");
                try args.append(planner.*);
            }
            try args.append(task);
            job.* = try startTaskJob(init.gpa, init.io, args.items, task);
            try replaceLog(init.gpa, last_output, "task running\n");
        },
    }
    return false;
}

fn startTaskJob(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, label: []const u8) !*TaskJob {
    const job = try allocator.create(TaskJob);
    errdefer allocator.destroy(job);
    const argv_copy = try dupArgv(allocator, argv);
    errdefer freeArgv(allocator, argv_copy);
    const label_copy = try allocator.dupe(u8, label);
    errdefer allocator.free(label_copy);
    job.* = .{
        .thread = undefined,
        .argv = argv_copy,
        .label = label_copy,
    };
    job.thread = try std.Thread.spawn(.{}, taskWorker, .{ job, io });
    return job;
}

fn taskWorker(job: *TaskJob, io: std.Io) void {
    const result = openfugu.cli.runWithIo(std.heap.page_allocator, io, job.argv) catch |err| {
        job.text = std.fmt.allocPrint(std.heap.page_allocator, "error: {s}\n", .{@errorName(err)}) catch null;
        job.done.store(true, .release);
        return;
    };
    job.code = result.code;
    job.text = result.text;
    job.done.store(true, .release);
}

fn finishCompletedJob(allocator: std.mem.Allocator, job: *TaskJob, last_output: *[]u8) !void {
    job.thread.join();
    try appendLog(allocator, last_output, job.label, job.text orelse "error: out of memory\n");
    job.deinit(allocator);
}

fn finishJob(allocator: std.mem.Allocator, job: *TaskJob) void {
    job.thread.join();
    job.deinit(allocator);
}

fn dupArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![][]const u8 {
    const copy = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(copy);
    var copied: usize = 0;
    errdefer for (copy[0..copied]) |arg| allocator.free(arg);
    for (argv, 0..) |arg, index| {
        copy[index] = try allocator.dupe(u8, arg);
        copied += 1;
    }
    return copy;
}

fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn runInteractiveCommand(init: std.process.Init, log: *[]u8, args: []const []const u8, label: []const u8) !void {
    const text = try runCommandText(init, args);
    defer init.gpa.free(text);
    try appendLog(init.gpa, log, label, text);
}

fn runCommandText(init: std.process.Init, args: []const []const u8) ![]u8 {
    var result = openfugu.cli.runWithIo(init.gpa, init.io, args) catch |err| {
        return std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
    };
    defer result.deinit(init.gpa);
    return init.gpa.dupe(u8, result.text);
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

fn appendHistory(allocator: std.mem.Allocator, history: *[]u8, input: []const u8) !void {
    const joined = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ if (std.mem.eql(u8, history.*, "No tasks yet.\n")) "" else history.*, input });
    allocator.free(history.*);
    history.* = if (joined.len > 4096) try allocator.dupe(u8, joined[joined.len - 4096 ..]) else joined;
    if (joined.ptr != history.*.ptr) allocator.free(joined);
}

fn tuiSize(env: *const std.process.Environ.Map) struct { width: u16, height: u16 } {
    return .{
        .width = envInt(env, "COLUMNS", 90),
        .height = envInt(env, "LINES", 24),
    };
}

fn envInt(env: *const std.process.Environ.Map, name: []const u8, fallback: u16) u16 {
    const value = env.get(name) orelse return fallback;
    const parsed = std.fmt.parseInt(u16, value, 10) catch return fallback;
    return parsed;
}

fn validAgent(value: []const u8) bool {
    return std.mem.eql(u8, value, "auto") or std.mem.eql(u8, value, "claude") or std.mem.eql(u8, value, "codex") or std.mem.eql(u8, value, "agy");
}

fn validMode(value: []const u8) bool {
    return std.mem.eql(u8, value, "auto") or std.mem.eql(u8, value, "single") or std.mem.eql(u8, value, "race") or std.mem.eql(u8, value, "ensemble");
}

fn validPlanner(value: []const u8) bool {
    return std.mem.eql(u8, value, "heuristic") or std.mem.eql(u8, value, "subscription-agent");
}
