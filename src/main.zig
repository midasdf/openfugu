const std = @import("std");
const builtin = @import("builtin");
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
            .clear_history => {
                try replaceLog(init.gpa, &history, "No tasks yet.\n");
                try replaceLog(init.gpa, &last_output, "history cleared\n");
                try writer.interface.writeAll(last_output);
            },
            .history => {
                try replaceLog(init.gpa, &last_output, history);
                try writer.interface.writeAll(last_output);
            },
            .help => {
                try replaceLog(init.gpa, &last_output,
                    \\Commands:
                    \\  :status  show current routing state
                    \\  :reset-routing reset routing to defaults
                    \\  :plan    preview workflow plan
                    \\  :route   preview routing without running
                    \\  :replay  show ledger replay for run id
                    \\  :doctor  show agent health
                    \\  :agents  list runnable agents
                    \\  :usage   show routing ledger summary
                    \\  :ledger  show recent ledger text
                    \\  :where   show cwd and git branch
                    \\  :pwd     show cwd and git branch
                    \\  :worktrees show git worktrees
                    \\  :git     show git status
                    \\  :log     show recent commits
                    \\  :diff    show git diff stat
                    \\  :patch   show git patch
                    \\  :verify  run local verification
                    \\  :build   run build
                    \\  :test    run tests
                    \\  :cancel  cancel running task
                    \\  :rerun   rerun last task
                    \\  :save    save current output to file
                    \\  :run     run shell command
                    \\  :rg      search files with ripgrep
                    \\  :todo    search todo markers
                    \\  :ls      list files
                    \\  :files   list files recursively
                    \\  :cd      change working directory
                    \\  :cwd     change working directory
                    \\  :load    run task text from file
                    \\  :open    show file in output pane
                    \\  :dry-run toggle dry-run mode
                    \\  :no-apply enter dry-run mode
                    \\  :apply   return to apply mode
                    \\  :agent   set agent: auto, claude, codex, agy
                    \\  :mode    set mode: auto, single, race, ensemble
                    \\  :planner set planner: heuristic, subscription-agent
                    \\  :clear   clear this session
                    \\  :clear-history clear input and task history
                    \\  :history show task history
                    \\  :quit    exit
                    \\
                    \\Keys: Up/Down input history, PageUp/PageDown output page, Home/End output top/bottom.
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
            .usage => {
                try runInteractiveCommand(init, &last_output, &.{ "openfugu", "usage" }, ":usage");
                try writer.interface.writeAll(last_output);
            },
            .ledger => {
                try runLedgerTail(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .where_ => {
                try runWhere(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .worktrees => {
                try runGitWorktrees(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .git => {
                try runGitStatus(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .log => {
                try runGitLog(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .diff => {
                try runGitDiff(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .patch => {
                try runGitPatch(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .verify => {
                try runLocalVerify(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .build => {
                try runLocalBuild(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .test_ => {
                try runLocalTests(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .cancel => {
                try replaceLog(init.gpa, &last_output, "no task running\n");
                try writer.interface.writeAll(last_output);
            },
            .status => {
                try replaceStatusLog(init.gpa, &last_output, dry_run, agent_filter, mode, planner, null);
                try writer.interface.writeAll(last_output);
            },
            .reset_routing => {
                try resetRouting(init.gpa, &dry_run, &agent_filter, &mode, &planner);
                try replaceLog(init.gpa, &last_output, "routing reset\n");
                try writer.interface.writeAll(last_output);
            },
            .dry_run => {
                dry_run = !dry_run;
                init.gpa.free(last_output);
                last_output = try std.fmt.allocPrint(init.gpa, "dry-run={}\n", .{dry_run});
                try writer.interface.writeAll(last_output);
            },
            .no_apply => {
                dry_run = true;
                try replaceLog(init.gpa, &last_output, "dry-run=true\n");
                try writer.interface.writeAll(last_output);
            },
            .apply => {
                dry_run = false;
                try replaceLog(init.gpa, &last_output, "apply=true\n");
                try writer.interface.writeAll(last_output);
            },
            .rerun => {
                try replaceLog(init.gpa, &last_output, "no previous task\n");
                try writer.interface.writeAll(last_output);
            },
            .save => |path| {
                try saveOutput(init, &last_output, path);
                try writer.interface.writeAll(last_output);
            },
            .run => |command| {
                try runShellCommand(init, &last_output, command);
                try writer.interface.writeAll(last_output);
            },
            .rg => |pattern| {
                try runRg(init, &last_output, pattern);
                try writer.interface.writeAll(last_output);
            },
            .todo => {
                try runTodo(init, &last_output);
                try writer.interface.writeAll(last_output);
            },
            .ls => |path| {
                try runLs(init, &last_output, path);
                try writer.interface.writeAll(last_output);
            },
            .files => |path| {
                try runFiles(init, &last_output, path);
                try writer.interface.writeAll(last_output);
            },
            .cwd => |path| {
                try changeCwd(init, &last_output, path);
                try writer.interface.writeAll(last_output);
            },
            .load => |path| {
                const text = loadTaskFile(init, &last_output, path) catch {
                    try writer.interface.writeAll(last_output);
                    continue;
                };
                defer init.gpa.free(text);
                try runReplTask(init, &last_output, &history, text, dry_run, agent_filter, mode, planner);
                try writer.interface.writeAll(last_output);
            },
            .open => |path| {
                try showFile(init, &last_output, path);
                try writer.interface.writeAll(last_output);
            },
            .plan => |task| {
                try runPlanPreview(init, &last_output, task, planner);
                try writer.interface.writeAll(last_output);
            },
            .route => |task| {
                try runRoutePreview(init, &last_output, task, agent_filter, mode, planner);
                try writer.interface.writeAll(last_output);
            },
            .replay => |run_id| {
                try runReplay(init, &last_output, run_id);
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
                try runReplTask(init, &last_output, &history, task, dry_run, agent_filter, mode, planner);
                try writer.interface.writeAll(last_output);
            },
        }
    }
    return openfugu.cli.exit_ok;
}

fn runReplTask(
    init: std.process.Init,
    last_output: *[]u8,
    history: *[]u8,
    task: []const u8,
    dry_run: bool,
    agent_filter: ?[]const u8,
    mode: []const u8,
    planner: []const u8,
) !void {
    try appendHistory(init.gpa, history, task);
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
    var result = openfugu.cli.runWithIo(init.gpa, init.io, args.items) catch |err| {
        if (err == error.InvalidArgs) {
            try replaceLog(init.gpa, last_output, "usage error\n");
            return;
        }
        const text = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
        defer init.gpa.free(text);
        try replaceLog(init.gpa, last_output, text);
        return;
    };
    defer result.deinit(init.gpa);
    try appendLog(init.gpa, last_output, task, result.text);
}

fn loadTaskFile(init: std.process.Init, last_output: *[]u8, path: []const u8) ![]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(128 * 1024)) catch |err| {
        const message = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
        defer init.gpa.free(message);
        try replaceLog(init.gpa, last_output, message);
        return err;
    };
    const task = std.mem.trim(u8, text, " \t\r\n");
    if (task.len == 0) {
        init.gpa.free(text);
        try replaceLog(init.gpa, last_output, "empty task file\n");
        return error.InvalidArgs;
    }
    if (task.len == text.len) return text;
    const copy = try init.gpa.dupe(u8, task);
    init.gpa.free(text);
    return copy;
}

fn showFile(init: std.process.Init, log: *[]u8, path: []const u8) !void {
    const spec = openfugu.cli.parseOpenSpec(path);
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, spec.path, init.gpa, .limited(128 * 1024)) catch |err| {
        const message = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
        defer init.gpa.free(message);
        try replaceLog(init.gpa, log, message);
        return;
    };
    defer init.gpa.free(text);
    const numbered = if (spec.line) |line|
        try openfugu.cli.numberedLinesAround(init.gpa, text, line, 20)
    else
        try openfugu.cli.numberedLines(init.gpa, text);
    defer init.gpa.free(numbered);
    try appendLog(init.gpa, log, spec.path, numbered);
}

fn rawRepl(init: std.process.Init) !u8 {
    var env = zz.Environment.fromEnvMap(init.environ_map);
    var term = try zz.Terminal.init(init.io, &env, .{ .alt_screen = true, .hide_cursor = false, .bracketed_paste = true });
    defer term.deinit();

    var input = zz.components.TextInput.init(init.gpa);
    defer input.deinit();
    input.setCharLimit(4096);
    input.setSuggestions(&.{
        ":help",
        ":status",
        ":reset-routing",
        ":plan ",
        ":route ",
        ":replay ",
        ":doctor",
        ":agents",
        ":usage",
        ":ledger",
        ":where",
        ":pwd",
        ":worktrees",
        ":git",
        ":log",
        ":diff",
        ":patch",
        ":verify",
        ":build",
        ":test",
        ":cancel",
        ":rerun",
        ":save ",
        ":run ",
        ":rg ",
        ":todo",
        ":ls",
        ":ls ",
        ":files",
        ":files ",
        ":cd ",
        ":cwd ",
        ":load ",
        ":open ",
        ":dry-run",
        ":no-apply",
        ":apply",
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
        ":clear-history",
        ":history",
        ":quit",
    });

    var last_output = try init.gpa.dupe(u8, "Type a task and press Enter.\n");
    defer init.gpa.free(last_output);
    var agents = try init.gpa.dupe(u8, ":agents to refresh\n");
    defer init.gpa.free(agents);
    var history = try init.gpa.dupe(u8, "No tasks yet.\n");
    defer init.gpa.free(history);
    var input_history = std.array_list.Managed([]u8).init(init.gpa);
    defer {
        for (input_history.items) |item| init.gpa.free(item);
        input_history.deinit();
    }
    try loadInputHistory(init, &input_history);
    var last_task: ?[]u8 = null;
    defer if (last_task) |task| init.gpa.free(task);
    var history_index: ?usize = null;
    var dry_run = false;
    var agent_filter: ?[]u8 = null;
    defer if (agent_filter) |value| init.gpa.free(value);
    var mode = try init.gpa.dupe(u8, "auto");
    defer init.gpa.free(mode);
    var planner = try init.gpa.dupe(u8, "heuristic");
    defer init.gpa.free(planner);
    // ponytail: one foreground task; add a queue if parallel TUI work matters.
    var job: ?*TaskJob = null;
    var output_offset: ?usize = null;
    defer if (job) |running_job| {
        running_job.cancel_requested.store(true, .release);
        running_job.thread.detach();
    };

    while (true) {
        if (job) |running_job| {
            if (running_job.done.load(.acquire)) {
                finishCompletedJob(init.gpa, running_job, &last_output) catch |err| {
                    init.gpa.free(last_output);
                    last_output = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
                };
                output_offset = null;
                job = null;
            }
        }

        const input_view = try input.view(init.gpa);
        defer init.gpa.free(input_view);
        const live_output = if (job) |running_job| try running_job.copyLive(init.gpa) else null;
        defer if (live_output) |text| init.gpa.free(text);
        try drawRaw(init, &term, input_view, live_output orelse last_output, agents, history, dry_run, agent_filter, mode, planner, if (job) |running_job| running_job.label else null, output_offset);

        var input_buf: [256]u8 = undefined;
        const read = try term.readInput(&input_buf, if (job == null) -1 else 100);
        if (read == 0) continue;
        const events = try zz.input.keyboard.parseAll(init.gpa, input_buf[0..read]);
        defer init.gpa.free(events);
        for (events) |event| {
            if (event != .key) continue;
            const key = event.key;
            if (key.modifiers.ctrl and key.key == .char and key.key.char == 'c') {
                if (job) |running_job| {
                    running_job.cancel_requested.store(true, .release);
                    try replaceLog(init.gpa, &last_output, "cancel requested\n");
                    continue;
                }
                return openfugu.cli.exit_ok;
            }
            switch (key.key) {
                .escape => {
                    if (job) |running_job| {
                        running_job.cancel_requested.store(true, .release);
                        try replaceLog(init.gpa, &last_output, "cancel requested\n");
                        continue;
                    }
                    return openfugu.cli.exit_ok;
                },
                .up => {
                    if (input_history.items.len > 0) {
                        const index = if (history_index) |current| current -| 1 else input_history.items.len - 1;
                        history_index = index;
                        try input.setValue(input_history.items[index]);
                    }
                },
                .down => {
                    if (history_index) |current| {
                        if (current + 1 < input_history.items.len) {
                            history_index = current + 1;
                            try input.setValue(input_history.items[current + 1]);
                        } else {
                            history_index = null;
                            try input.setValue("");
                        }
                    }
                },
                .home => output_offset = 0,
                .end => output_offset = null,
                .page_up => output_offset = pageOutputUp(init, &term, last_output, output_offset),
                .page_down => output_offset = pageOutputDown(init, &term, last_output, output_offset),
                .enter => {
                    const line = try init.gpa.dupe(u8, input.getValue());
                    defer init.gpa.free(line);
                    try input.setValue("");
                    history_index = null;
                    var rerun_task: ?[]const u8 = null;
                    switch (openfugu.cli.interactiveInput(line)) {
                        .empty => {},
                        .clear_history => {
                            for (input_history.items) |item| init.gpa.free(item);
                            input_history.clearRetainingCapacity();
                            try saveInputHistory(init, &input_history);
                            if (last_task) |task| init.gpa.free(task);
                            last_task = null;
                        },
                        .rerun => {
                            rerun_task = last_task orelse {
                                try replaceLog(init.gpa, &last_output, "no previous task\n");
                                continue;
                            };
                            try input_history.append(try init.gpa.dupe(u8, std.mem.trim(u8, line, " \t\r\n")));
                            try saveInputHistory(init, &input_history);
                        },
                        .task => |task| {
                            if (last_task) |old| init.gpa.free(old);
                            last_task = try init.gpa.dupe(u8, task);
                            try input_history.append(try init.gpa.dupe(u8, task));
                            try saveInputHistory(init, &input_history);
                        },
                        .load => |path| {
                            const text = loadTaskFile(init, &last_output, path) catch continue;
                            defer init.gpa.free(text);
                            if (last_task) |old| init.gpa.free(old);
                            last_task = try init.gpa.dupe(u8, text);
                            try input_history.append(try init.gpa.dupe(u8, std.mem.trim(u8, line, " \t\r\n")));
                            try saveInputHistory(init, &input_history);
                        },
                        else => {
                            try input_history.append(try init.gpa.dupe(u8, std.mem.trim(u8, line, " \t\r\n")));
                            try saveInputHistory(init, &input_history);
                        },
                    }
                    const should_quit = try handleInteractiveLine(init, rerun_task orelse line, &last_output, &agents, &history, &dry_run, &agent_filter, &mode, &planner, &term, &job);
                    output_offset = null;
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
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    live_mutex: std.atomic.Mutex = .unlocked,
    argv: [][]const u8,
    label: []u8,
    live_text: ?[]u8 = null,
    text: ?[]u8 = null,
    code: u8 = openfugu.cli.exit_planner,

    fn deinit(self: *TaskJob, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        allocator.free(self.label);
        if (self.live_text) |text| std.heap.page_allocator.free(text);
        if (self.text) |text| std.heap.page_allocator.free(text);
        allocator.destroy(self);
    }

    fn copyLive(self: *TaskJob, allocator: std.mem.Allocator) !?[]u8 {
        self.lockLive();
        defer self.live_mutex.unlock();
        return if (self.live_text) |text| try allocator.dupe(u8, text) else null;
    }

    fn appendLive(self: *TaskJob, text: []const u8) !void {
        self.lockLive();
        defer self.live_mutex.unlock();
        const joined = try std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ self.live_text orelse "", text });
        if (self.live_text) |old| std.heap.page_allocator.free(old);
        self.live_text = if (joined.len > 64 * 1024) try std.heap.page_allocator.dupe(u8, joined[joined.len - 64 * 1024 ..]) else joined;
        if (joined.ptr != self.live_text.?.ptr) std.heap.page_allocator.free(joined);
    }

    fn lockLive(self: *TaskJob) void {
        while (!self.live_mutex.tryLock()) std.Thread.yield() catch {};
    }
};

fn pageOutputUp(init: std.process.Init, term: *zz.Terminal, output: []const u8, current: ?usize) ?usize {
    const page_rows = outputPageRows(init, term);
    const total_rows = outputLineRows(output);
    if (total_rows <= page_rows) return 0;
    if (current) |offset| return offset -| page_rows;
    const bottom_offset = total_rows - page_rows;
    return bottom_offset -| page_rows;
}

fn pageOutputDown(init: std.process.Init, term: *zz.Terminal, output: []const u8, current: ?usize) ?usize {
    const offset = current orelse return null;
    const page_rows = outputPageRows(init, term);
    const total_rows = outputLineRows(output);
    const next = offset + page_rows;
    if (next + page_rows >= total_rows) return null;
    return next;
}

fn outputPageRows(init: std.process.Init, term: *zz.Terminal) usize {
    const size = term.getSize() catch null;
    const fallback_size = tuiSize(init.environ_map);
    const height = if (size) |value| value.rows else fallback_size.height;
    return @max(@as(usize, 4), @as(usize, height -| 12));
}

fn outputLineRows(output: []const u8) usize {
    if (output.len == 0) return 1;
    return std.mem.count(u8, output, "\n") + 1;
}

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
    running_label: ?[]const u8,
    output_offset: ?usize,
) !void {
    const size = term.getSize() catch null;
    const fallback_size = tuiSize(init.environ_map);
    const width = if (size) |value| value.cols else fallback_size.width;
    const height = if (size) |value| value.rows else fallback_size.height;
    const status = try statusText(init.gpa, dry_run, agent_filter, mode, planner, running_label);
    defer init.gpa.free(status);
    const screen = try openfugu.tui.renderDashboardSized(init.gpa, .{
        .status = status,
        .input = input,
        .output = output,
        .output_bottom = output_offset == null,
        .output_offset = output_offset,
        .agents = agents,
        .history = history,
    }, width, height);
    defer init.gpa.free(screen);
    try term.writer().writeAll(zz.ansi.screen_clear ++ zz.ansi.cursor_home);
    try term.writer().writeAll(screen);
    try term.flush();
}

fn statusText(
    allocator: std.mem.Allocator,
    dry_run: bool,
    agent_filter: ?[]const u8,
    mode: []const u8,
    planner: []const u8,
    running_label: ?[]const u8,
) ![]u8 {
    if (running_label) |label| {
        return std.fmt.allocPrint(allocator, "{s} task={s} agent={s} mode={s} planner={s}", .{
            if (dry_run) "running dry-run" else "running apply",
            label,
            agent_filter orelse "auto",
            mode,
            planner,
        });
    }
    return std.fmt.allocPrint(allocator, "{s} agent={s} mode={s} planner={s}", .{
        if (dry_run) "ready dry-run" else "ready apply",
        agent_filter orelse "auto",
        mode,
        planner,
    });
}

fn replaceStatusLog(
    allocator: std.mem.Allocator,
    log: *[]u8,
    dry_run: bool,
    agent_filter: ?[]const u8,
    mode: []const u8,
    planner: []const u8,
    running_label: ?[]const u8,
) !void {
    const text = try statusText(allocator, dry_run, agent_filter, mode, planner, running_label);
    defer allocator.free(text);
    const line = try std.fmt.allocPrint(allocator, "{s}\n", .{text});
    defer allocator.free(line);
    try replaceLog(allocator, log, line);
}

fn resetRouting(
    allocator: std.mem.Allocator,
    dry_run: *bool,
    agent_filter: *?[]u8,
    mode: *[]u8,
    planner: *[]u8,
) !void {
    dry_run.* = false;
    if (agent_filter.*) |old| allocator.free(old);
    agent_filter.* = null;
    allocator.free(mode.*);
    mode.* = try allocator.dupe(u8, "auto");
    allocator.free(planner.*);
    planner.* = try allocator.dupe(u8, "heuristic");
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
        .clear_history => {
            try replaceLog(init.gpa, history, "No tasks yet.\n");
            try replaceLog(init.gpa, last_output, "history cleared\n");
        },
        .history => try replaceLog(init.gpa, last_output, history.*),
        .help => try replaceLog(init.gpa, last_output,
            \\Commands:
            \\  :status  show current routing state
            \\  :reset-routing reset routing to defaults
            \\  :plan    preview workflow plan
            \\  :route   preview routing without running
            \\  :replay  show ledger replay for run id
            \\  :doctor  show agent health
            \\  :agents  list runnable agents
            \\  :usage   show routing ledger summary
            \\  :ledger  show recent ledger text
            \\  :where   show cwd and git branch
            \\  :pwd     show cwd and git branch
            \\  :worktrees show git worktrees
            \\  :git     show git status
            \\  :log     show recent commits
            \\  :diff    show git diff stat
            \\  :patch   show git patch
            \\  :verify  run local verification
            \\  :build   run build
            \\  :test    run tests
            \\  :cancel  cancel running task
            \\  :rerun   rerun last task
            \\  :save    save current output to file
            \\  :run     run shell command
            \\  :rg      search files with ripgrep
            \\  :todo    search todo markers
            \\  :ls      list files
            \\  :files   list files recursively
            \\  :cd      change working directory
            \\  :cwd     change working directory
            \\  :load    run task text from file
            \\  :open    show file in output pane
            \\  :dry-run toggle dry-run mode
            \\  :no-apply enter dry-run mode
            \\  :apply   return to apply mode
            \\  :agent   set agent: auto, claude, codex, agy
            \\  :mode    set mode: auto, single, race, ensemble
            \\  :planner set planner: heuristic, subscription-agent
            \\  :clear   clear this session
            \\  :clear-history clear input and task history
            \\  :history show task history
            \\  :quit    exit
            \\
            \\Keys: Up/Down input history, PageUp/PageDown output page, Home/End output top/bottom.
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
        .usage => try runInteractiveCommand(init, last_output, &.{ "openfugu", "usage" }, ":usage"),
        .ledger => try runLedgerTail(init, last_output),
        .where_ => try runWhere(init, last_output),
        .worktrees => try runGitWorktrees(init, last_output),
        .git => try runGitStatus(init, last_output),
        .log => try runGitLog(init, last_output),
        .diff => try runGitDiff(init, last_output),
        .patch => try runGitPatch(init, last_output),
        .verify => try runLocalVerify(init, last_output),
        .build => try runLocalBuild(init, last_output),
        .test_ => try runLocalTests(init, last_output),
        .cancel => {
            if (job.*) |running_job| {
                running_job.cancel_requested.store(true, .release);
                try replaceLog(init.gpa, last_output, "cancel requested\n");
            } else {
                try replaceLog(init.gpa, last_output, "no task running\n");
            }
        },
        .status => try replaceStatusLog(init.gpa, last_output, dry_run.*, agent_filter.*, mode.*, planner.*, if (job.*) |running_job| running_job.label else null),
        .reset_routing => {
            try resetRouting(init.gpa, dry_run, agent_filter, mode, planner);
            try replaceLog(init.gpa, last_output, "routing reset\n");
        },
        .dry_run => {
            dry_run.* = !dry_run.*;
            init.gpa.free(last_output.*);
            last_output.* = try std.fmt.allocPrint(init.gpa, "dry-run={}\n", .{dry_run.*});
        },
        .no_apply => {
            dry_run.* = true;
            try replaceLog(init.gpa, last_output, "dry-run=true\n");
        },
        .apply => {
            dry_run.* = false;
            try replaceLog(init.gpa, last_output, "apply=true\n");
        },
        .rerun => try replaceLog(init.gpa, last_output, "no previous task\n"),
        .save => |path| try saveOutput(init, last_output, path),
        .run => |command| {
            if (job.* != null) {
                try replaceLog(init.gpa, last_output, "task already running\n");
                return false;
            }
            try drawRaw(init, term, command, last_output.*, agents.*, history.*, dry_run.*, agent_filter.*, mode.*, planner.*, command, null);
            job.* = try startTaskJob(init.gpa, init.io, &.{ "/bin/sh", "-lc", command }, command, false);
            try replaceLog(init.gpa, last_output, "command running\n");
        },
        .rg => |pattern| try runRg(init, last_output, pattern),
        .todo => try runTodo(init, last_output),
        .ls => |path| try runLs(init, last_output, path),
        .files => |path| try runFiles(init, last_output, path),
        .cwd => |path| {
            if (job.* != null) {
                try replaceLog(init.gpa, last_output, "task already running\n");
                return false;
            }
            try changeCwd(init, last_output, path);
        },
        .load => |path| {
            const text = loadTaskFile(init, last_output, path) catch return false;
            defer init.gpa.free(text);
            try startOpenfuguTask(init, text, last_output, agents, history, dry_run, agent_filter, mode, planner, term, job);
        },
        .open => |path| try showFile(init, last_output, path),
        .plan => |task| try runPlanPreview(init, last_output, task, planner.*),
        .route => |task| try runRoutePreview(init, last_output, task, agent_filter.*, mode.*, planner.*),
        .replay => |run_id| try runReplay(init, last_output, run_id),
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
            try startOpenfuguTask(init, task, last_output, agents, history, dry_run, agent_filter, mode, planner, term, job);
        },
    }
    return false;
}

fn startOpenfuguTask(
    init: std.process.Init,
    task: []const u8,
    last_output: *[]u8,
    agents: *[]u8,
    history: *[]u8,
    dry_run: *bool,
    agent_filter: *?[]u8,
    mode: *[]u8,
    planner: *[]u8,
    term: *zz.Terminal,
    job: *?*TaskJob,
) !void {
    if (job.* != null) {
        try replaceLog(init.gpa, last_output, "task already running\n");
        return;
    }
    try appendHistory(init.gpa, history, task);
    try drawRaw(init, term, task, last_output.*, agents.*, history.*, dry_run.*, agent_filter.*, mode.*, planner.*, task, null);
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
    job.* = try startTaskJob(init.gpa, init.io, args.items, task, true);
    try replaceLog(init.gpa, last_output, "task running\n");
}

fn startTaskJob(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, label: []const u8, replace_with_self: bool) !*TaskJob {
    const job = try allocator.create(TaskJob);
    errdefer allocator.destroy(job);
    const argv_copy = try dupArgv(allocator, argv);
    errdefer freeArgv(allocator, argv_copy);
    if (replace_with_self) {
        const self_exe_z = try std.process.executablePathAlloc(io, allocator);
        defer allocator.free(self_exe_z);
        const self_exe = try allocator.dupe(u8, self_exe_z);
        errdefer allocator.free(self_exe);
        allocator.free(argv_copy[0]);
        argv_copy[0] = self_exe;
    }
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
    job.text = runTaskChild(job, io) catch |err| {
        job.text = std.fmt.allocPrint(std.heap.page_allocator, "error: {s}\n", .{@errorName(err)}) catch null;
        job.done.store(true, .release);
        return;
    };
    job.done.store(true, .release);
}

fn runTaskChild(job: *TaskJob, io: std.Io) ![]u8 {
    var child = try std.process.spawn(io, .{
        .argv = job.argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });

    var stdout_thread = try std.Thread.spawn(.{}, drainPipe, .{ job, child.stdout.? });
    var stderr_thread = try std.Thread.spawn(.{}, drainPipe, .{ job, child.stderr.? });
    defer {
        stdout_thread.join();
        stderr_thread.join();
        if (child.stdout) |file| file.close(io);
        if (child.stderr) |file| file.close(io);
    }

    const term = if (builtin.os.tag == .linux) linux_wait: {
        while (true) {
            if (job.cancel_requested.load(.acquire)) {
                _ = signalChildGroup(child, .TERM);
                try io.sleep(std.Io.Duration.fromMilliseconds(250), .awake);
                _ = signalChildGroup(child, .KILL);
                _ = try child.wait(io);
                job.code = openfugu.cli.exit_sigint;
                return std.fmt.allocPrint(std.heap.page_allocator, "canceled\n", .{});
            }
            if (try waitNoHang(child.id.?)) |done_term| {
                child.id = null;
                break :linux_wait done_term;
            }
            try io.sleep(std.Io.Duration.fromMilliseconds(100), .awake);
        }
    } else try child.wait(io);

    job.code = taskExitCode(term);
    return (try job.copyLive(std.heap.page_allocator)) orelse try std.heap.page_allocator.dupe(u8, "");
}

fn drainPipe(job: *TaskJob, file: std.Io.File) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(file.handle, &buf) catch return;
        if (n == 0) return;
        job.appendLive(buf[0..n]) catch return;
    }
}

fn waitNoHang(pid: std.posix.pid_t) !?std.process.Child.Term {
    var status: u32 = 0;
    const waited: isize = @bitCast(std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG));
    if (waited == 0) return null;
    if (waited < 0) return error.Unexpected;
    if (std.os.linux.W.IFEXITED(status)) return .{ .exited = std.os.linux.W.EXITSTATUS(status) };
    if (std.os.linux.W.IFSIGNALED(status)) return .{ .signal = std.os.linux.W.TERMSIG(status) };
    return .{ .unknown = status };
}

fn signalChildGroup(child: std.process.Child, sig: std.posix.SIG) bool {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return false;
    const pid = child.id orelse return false;
    std.posix.kill(-pid, sig) catch {
        std.posix.kill(pid, sig) catch return false;
    };
    return true;
}

fn taskExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => openfugu.cli.exit_sigint,
        else => openfugu.cli.exit_planner,
    };
}

fn finishCompletedJob(allocator: std.mem.Allocator, job: *TaskJob, last_output: *[]u8) !void {
    job.thread.join();
    const text = job.text orelse "error: out of memory\n";
    const output = try std.fmt.allocPrint(allocator, "result={s} exit={d}\n{s}", .{ taskResultLabel(job.code), job.code, text });
    defer allocator.free(output);
    try appendLog(allocator, last_output, job.label, output);
    job.deinit(allocator);
}

fn taskResultLabel(code: u8) []const u8 {
    if (code == openfugu.cli.exit_ok) return "ok";
    if (code == openfugu.cli.exit_sigint) return "canceled";
    return "failed";
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

fn runLedgerTail(init: std.process.Init, log: *[]u8) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, ".openfugu/ledger.jsonl", init.gpa, .limited(64 * 1024)) catch {
        try appendLog(init.gpa, log, ":ledger", "no ledger\n");
        return;
    };
    defer init.gpa.free(text);
    var start = if (text.len > 8192) text.len - 8192 else 0;
    if (start != 0) {
        if (std.mem.indexOfScalar(u8, text[start..], '\n')) |newline| start += newline + 1;
    }
    try appendLog(init.gpa, log, ":ledger", if (text.len == 0) "no ledger\n" else text[start..]);
}

fn runWhere(init: std.process.Init, log: *[]u8) !void {
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);
    var branch_result = openfugu.runner.run(init.gpa, init.io, .{
        .executable = "git",
        .argv = &.{ "git", "branch", "--show-current" },
        .cwd = ".",
        .stdout_tail_bytes = 256,
        .stderr_tail_bytes = 0,
        .timeout_ms = 1000,
    }) catch null;
    defer if (branch_result) |*result| result.deinit(init.gpa);
    const branch = if (branch_result) |result|
        std.mem.trim(u8, result.stdout_tail, " \t\r\n")
    else
        "unknown";
    const text = try std.fmt.allocPrint(init.gpa, "cwd={s}\nbranch={s}\n", .{ cwd, if (branch.len == 0) "detached" else branch });
    defer init.gpa.free(text);
    try appendLog(init.gpa, log, ":where", text);
}

fn runGitStatus(init: std.process.Init, log: *[]u8) !void {
    try runGitCommand(init, log, ":git", &.{ "git", "status", "--short", "--branch" }, "clean\n");
}

fn runGitWorktrees(init: std.process.Init, log: *[]u8) !void {
    try runGitCommand(init, log, ":worktrees", &.{ "git", "worktree", "list", "--porcelain" }, "no worktrees\n");
}

fn runGitLog(init: std.process.Init, log: *[]u8) !void {
    try runGitCommand(init, log, ":log", &.{ "git", "log", "--oneline", "-n", "20" }, "no commits\n");
}

fn runGitDiff(init: std.process.Init, log: *[]u8) !void {
    try runGitCommand(init, log, ":diff", &.{ "git", "diff", "--stat" }, "no diff\n");
}

fn runGitPatch(init: std.process.Init, log: *[]u8) !void {
    try runGitCommand(init, log, ":patch", &.{ "git", "diff", "--no-ext-diff" }, "no patch\n");
}

fn runRg(init: std.process.Init, log: *[]u8, pattern: []const u8) !void {
    var result = openfugu.runner.run(init.gpa, init.io, .{
        .executable = "rg",
        .argv = &.{ "rg", "-n", "--", pattern },
        .cwd = ".",
        .stdout_tail_bytes = 16 * 1024,
        .stderr_tail_bytes = 2048,
        .timeout_ms = 5000,
    }) catch |err| {
        const text = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
        defer init.gpa.free(text);
        try appendLog(init.gpa, log, pattern, text);
        return;
    };
    defer result.deinit(init.gpa);
    const text = if (result.exit_code == 0) result.stdout_tail else if (result.exit_code == 1) "no matches\n" else result.stderr_tail;
    try appendLog(init.gpa, log, pattern, if (text.len == 0) "no matches\n" else text);
}

fn runTodo(init: std.process.Init, log: *[]u8) !void {
    var result = openfugu.runner.run(init.gpa, init.io, .{
        .executable = "rg",
        .argv = &.{ "rg", "-n", "-e", "T[O]DO|F[I]XME|X[X]X" },
        .cwd = ".",
        .stdout_tail_bytes = 16 * 1024,
        .stderr_tail_bytes = 2048,
        .timeout_ms = 5000,
    }) catch |err| {
        const text = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
        defer init.gpa.free(text);
        try appendLog(init.gpa, log, ":todo", text);
        return;
    };
    defer result.deinit(init.gpa);
    const text = if (result.exit_code == 0) result.stdout_tail else if (result.exit_code == 1) "no todos\n" else result.stderr_tail;
    try appendLog(init.gpa, log, ":todo", if (text.len == 0) "no todos\n" else text);
}

fn runLs(init: std.process.Init, log: *[]u8, path: []const u8) !void {
    var result = openfugu.runner.run(init.gpa, init.io, .{
        .executable = "ls",
        .argv = &.{ "ls", "-la", "--", path },
        .cwd = ".",
        .stdout_tail_bytes = 16 * 1024,
        .stderr_tail_bytes = 2048,
        .timeout_ms = 5000,
    }) catch |err| {
        const text = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
        defer init.gpa.free(text);
        try appendLog(init.gpa, log, path, text);
        return;
    };
    defer result.deinit(init.gpa);
    const text = if (result.exit_code == 0) result.stdout_tail else result.stderr_tail;
    try appendLog(init.gpa, log, path, if (text.len == 0) "empty\n" else text);
}

fn runFiles(init: std.process.Init, log: *[]u8, path: []const u8) !void {
    var result = openfugu.runner.run(init.gpa, init.io, .{
        .executable = "rg",
        .argv = &.{ "rg", "--files", "--", path },
        .cwd = ".",
        .stdout_tail_bytes = 16 * 1024,
        .stderr_tail_bytes = 2048,
        .timeout_ms = 5000,
    }) catch |err| {
        const text = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
        defer init.gpa.free(text);
        try appendLog(init.gpa, log, path, text);
        return;
    };
    defer result.deinit(init.gpa);
    const text = if (result.exit_code == 0) result.stdout_tail else result.stderr_tail;
    try appendLog(init.gpa, log, path, if (text.len == 0) "no files\n" else text);
}

fn runGitCommand(init: std.process.Init, log: *[]u8, label: []const u8, argv: []const []const u8, empty_text: []const u8) !void {
    var result = openfugu.runner.run(init.gpa, init.io, .{
        .executable = "git",
        .argv = argv,
        .cwd = ".",
        .stdout_tail_bytes = 8192,
        .stderr_tail_bytes = 2048,
        .timeout_ms = 5000,
    }) catch |err| {
        const text = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
        defer init.gpa.free(text);
        try appendLog(init.gpa, log, label, text);
        return;
    };
    defer result.deinit(init.gpa);
    const text = if (result.exit_code == 0) result.stdout_tail else result.stderr_tail;
    try appendLog(init.gpa, log, label, if (text.len == 0) empty_text else text);
}

fn runLocalVerify(init: std.process.Init, log: *[]u8) !void {
    try runVerificationCommands(init, log, ":verify", &.{
        .{ .name = "build", .argv = &.{ "zig", "build" } },
        .{ .name = "test", .argv = &.{ "zig", "build", "test" } },
    });
}

fn runLocalBuild(init: std.process.Init, log: *[]u8) !void {
    try runVerificationCommands(init, log, ":build", &.{
        .{ .name = "build", .argv = &.{ "zig", "build" } },
    });
}

fn runLocalTests(init: std.process.Init, log: *[]u8) !void {
    try runVerificationCommands(init, log, ":test", &.{
        .{ .name = "test", .argv = &.{ "zig", "build", "test" } },
    });
}

fn runVerificationCommands(init: std.process.Init, log: *[]u8, label: []const u8, commands: []const openfugu.verify.Command) !void {
    var verification = try openfugu.verify.run(init.gpa, init.io, ".", commands);
    defer verification.deinit(init.gpa);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(init.gpa);
    try out.print(init.gpa, "passed={}\n", .{verification.passed});
    for (verification.commands) |command| {
        try out.print(init.gpa, "{s} exit={?}\n", .{ command.name, command.exit_code });
        if (command.stdout_tail.len != 0) try out.appendSlice(init.gpa, command.stdout_tail);
        if (command.stderr_tail.len != 0) try out.appendSlice(init.gpa, command.stderr_tail);
    }
    const text = try out.toOwnedSlice(init.gpa);
    defer init.gpa.free(text);
    try appendLog(init.gpa, log, label, text);
}

fn runReplay(init: std.process.Init, log: *[]u8, run_id: []const u8) !void {
    var args = [_][]const u8{ "openfugu", "replay", run_id };
    const text = try runCommandText(init, &args);
    defer init.gpa.free(text);
    try appendLog(init.gpa, log, run_id, text);
}

fn runPlanPreview(init: std.process.Init, log: *[]u8, task: []const u8, planner: []const u8) !void {
    var args = std.array_list.Managed([]const u8).init(init.gpa);
    defer args.deinit();
    try args.append("openfugu");
    try args.append("plan");
    if (!std.mem.eql(u8, planner, "heuristic")) {
        try args.append("--planner");
        try args.append(planner);
    }
    try args.append(task);
    const text = try runCommandText(init, args.items);
    defer init.gpa.free(text);
    try appendLog(init.gpa, log, task, text);
}

fn runRoutePreview(
    init: std.process.Init,
    log: *[]u8,
    task: []const u8,
    agent_filter: ?[]const u8,
    mode: []const u8,
    planner: []const u8,
) !void {
    var args = std.array_list.Managed([]const u8).init(init.gpa);
    defer args.deinit();
    try args.append("openfugu");
    try args.append("--route-only");
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
    const text = try runCommandText(init, args.items);
    defer init.gpa.free(text);
    try appendLog(init.gpa, log, task, text);
}

fn runCommandText(init: std.process.Init, args: []const []const u8) ![]u8 {
    var result = openfugu.cli.runWithIo(init.gpa, init.io, args) catch |err| {
        return std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
    };
    defer result.deinit(init.gpa);
    return init.gpa.dupe(u8, result.text);
}

fn loadInputHistory(init: std.process.Init, history: *std.array_list.Managed([]u8)) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, ".openfugu/tui-history", init.gpa, .limited(64 * 1024)) catch return;
    defer init.gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) try history.append(try init.gpa.dupe(u8, trimmed));
    }
}

fn saveInputHistory(init: std.process.Init, history: *const std.array_list.Managed([]u8)) !void {
    try std.Io.Dir.cwd().createDirPath(init.io, ".openfugu");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(init.gpa);
    const start = history.items.len -| 200;
    for (history.items[start..]) |item| {
        try out.appendSlice(init.gpa, item);
        try out.append(init.gpa, '\n');
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = ".openfugu/tui-history", .data = out.items });
}

fn saveOutput(init: std.process.Init, log: *[]u8, path: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = log.* });
    const message = try std.fmt.allocPrint(init.gpa, "saved {s}\n", .{path});
    defer init.gpa.free(message);
    try replaceLog(init.gpa, log, message);
}

fn runShellCommand(init: std.process.Init, log: *[]u8, command: []const u8) !void {
    var result = openfugu.runner.run(init.gpa, init.io, .{
        .executable = "/bin/sh",
        .argv = &.{ "/bin/sh", "-lc", command },
        .cwd = ".",
        .stdout_tail_bytes = 8192,
        .stderr_tail_bytes = 4096,
        .timeout_ms = 30_000,
    }) catch |err| {
        const text = try std.fmt.allocPrint(init.gpa, "error: {s}\n", .{@errorName(err)});
        defer init.gpa.free(text);
        try appendLog(init.gpa, log, command, text);
        return;
    };
    defer result.deinit(init.gpa);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(init.gpa);
    if (result.timed_out) try out.appendSlice(init.gpa, "timed out\n");
    if (result.exit_code) |code| {
        if (code != 0) try out.print(init.gpa, "exit={}\n", .{code});
    }
    if (result.stdout_tail.len != 0) try out.appendSlice(init.gpa, result.stdout_tail);
    if (result.stderr_tail.len != 0) try out.appendSlice(init.gpa, result.stderr_tail);
    if (out.items.len == 0) try out.appendSlice(init.gpa, "ok\n");
    const text = try out.toOwnedSlice(init.gpa);
    defer init.gpa.free(text);
    try appendLog(init.gpa, log, command, text);
}

fn changeCwd(init: std.process.Init, log: *[]u8, path: []const u8) !void {
    try std.process.setCurrentPath(init.io, path);
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);
    const text = try std.fmt.allocPrint(init.gpa, "cwd={s}\n", .{cwd});
    defer init.gpa.free(text);
    try replaceLog(init.gpa, log, text);
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
