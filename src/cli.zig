const std = @import("std");
const config = @import("config.zig");
const heuristic = @import("planner/heuristic.zig");
const planner = @import("planner/planner.zig");
const doctor = @import("obs/doctor.zig");
const probe = @import("adapter/probe.zig");
const runner = @import("proc/runner.zig");
const usage = @import("obs/usage.zig");
const replay = @import("obs/replay.zig");
const claude_code = @import("adapter/claude_code.zig");
const codex = @import("adapter/codex.zig");
const antigravity = @import("adapter/antigravity.zig");
const conductor = @import("conductor/loop.zig");
const policy = @import("conductor/policy.zig");
const verify = @import("verify/commands.zig");
const types = @import("core/types.zig");
const adapter = @import("adapter/adapter.zig");
const ledger = @import("obs/ledger.zig");
const jobs = @import("obs/jobs.zig");
const model_review = @import("verify/model_review.zig");

const claude_version_argv = [_][]const u8{ "claude", "--version" };
const claude_auth_argv = [_][]const u8{ "claude", "auth", "status" };
const codex_version_argv = [_][]const u8{ "codex", "--version" };
const codex_auth_argv = [_][]const u8{ "codex", "login", "status" };
const agy_version_argv = [_][]const u8{ "agy", "--version" };
const agy_auth_argv = [_][]const u8{ "agy", "models" };

const RoutingCandidate = struct {
    spec: probe.DetectSpec,
    report: probe.AgentReport,
    score: i64,
    stats: LedgerStats = .{},
};

const LedgerStats = struct {
    calls: u64 = 0,
    successes: u64 = 0,
    failures: u64 = 0,
};

pub const exit_ok: u8 = 0;
pub const exit_usage: u8 = 2;
pub const exit_no_agent: u8 = 3;
pub const exit_budget: u8 = 4;
pub const exit_verify: u8 = 5;
pub const exit_workspace: u8 = 6;
pub const exit_planner: u8 = 7;
pub const exit_compat: u8 = 8;
pub const exit_sigint: u8 = 130;

pub const Result = struct {
    code: u8,
    text: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !Result {
    if (try taskText(args) != null) {
        return .{
            .code = exit_no_agent,
            .text = try allocator.dupe(u8, "no subscription-compatible agent available; run `openfugu doctor` for details\n"),
        };
    }
    return .{ .code = exit_ok, .text = try runAlloc(allocator, args) };
}

pub fn runWithIo(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !Result {
    const specs = defaultDetectSpecs();
    return runWithProbeSpecs(allocator, io, args, &specs);
}

pub fn runWithProbeSpecs(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    specs: []const probe.DetectSpec,
) !Result {
    return runWithProbeSpecsInRepo(allocator, io, args, specs, ".", ".openfugu/worktrees", defaultVerifyCommands());
}

pub fn runWithProbeSpecsInRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    specs: []const probe.DetectSpec,
    repo_path: []const u8,
    worktree_root: []const u8,
    verify_commands: []const verify.Command,
) !Result {
    if (args.len <= 1) return run(allocator, args);
    if (isHelp(args[1])) return .{ .code = exit_ok, .text = try helpText(allocator) };
    if (std.mem.eql(u8, args[1], "usage")) {
        const ledger_path = try runLedgerPath(allocator, worktree_root);
        defer allocator.free(ledger_path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, ledger_path, allocator, .limited(1024 * 1024)) catch "";
        const owns_text = text.len != 0;
        defer if (owns_text) allocator.free(text);
        const summary = usage.summarizeLedgerText(text);
        return .{
            .code = exit_ok,
            .text = try std.fmt.allocPrint(allocator, "calls={d} reported={d} unavailable={d} rate_limits={d} successes={d} failures={d}\n", .{
                summary.calls,
                summary.reported_tokens,
                summary.unavailable_tokens,
                summary.rate_limits,
                summary.successes,
                summary.failures,
            }),
        };
    }
    if (std.mem.eql(u8, args[1], "replay")) {
        if (args.len < 3) return error.InvalidArgs;
        const ledger_path = try runLedgerPath(allocator, worktree_root);
        defer allocator.free(ledger_path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, ledger_path, allocator, .limited(1024 * 1024)) catch "";
        const owns_text = text.len != 0;
        defer if (owns_text) allocator.free(text);
        return .{ .code = exit_ok, .text = try replay.renderLedgerText(allocator, args[2], text) };
    }
    // list-agents is an alias for agents that better matches the
    // verb-noun subcommand style used by the skill.
    if (std.mem.eql(u8, args[1], "list-agents")) {
        const reports = try collectReports(allocator, io, specs);
        defer probe.freeReports(allocator, reports);
        return .{ .code = exit_ok, .text = try renderAgents(allocator, reports) };
    }
    if (std.mem.eql(u8, args[1], "status")) {
        const reports = try collectReports(allocator, io, specs);
        defer probe.freeReports(allocator, reports);
        const ledger_path = try runLedgerPath(allocator, worktree_root);
        defer allocator.free(ledger_path);
        const ledger_text = std.Io.Dir.cwd().readFileAlloc(io, ledger_path, allocator, .limited(1024 * 1024)) catch "";
        const owns_ledger = ledger_text.len != 0;
        defer if (owns_ledger) allocator.free(ledger_text);
        const summary = usage.summarizeLedgerText(ledger_text);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.print(allocator, "agents={d} runnable={d} ledger_calls={d} successes={d} failures={d} rate_limits={d}\n", .{
            reports.len,
            countRunnable(reports),
            summary.calls,
            summary.successes,
            summary.failures,
            summary.rate_limits,
        });
        for (reports) |agent| {
            try out.print(allocator, "  {s} compatibility={s} auth={s} runnable={}\n", .{
                agent.name,
                @tagName(agent.compatibility),
                @tagName(agent.auth),
                agent.runnable,
            });
        }
        return .{ .code = exit_ok, .text = try out.toOwnedSlice(allocator) };
    }
    // route <task> is an explicit form of "--route-only <task>". It is
    // the recommended entry point for coding agents that want to inspect
    // routing before spending quota on a real run. Flags may appear
    // before or after the task text; the first non-flag token after
    // `route` is the task.
    if (std.mem.eql(u8, args[1], "route")) {
        const task = subcommandTask(args[2..]) orelse {
            return .{
                .code = exit_usage,
                .text = try allocator.dupe(u8, "usage: openfugu route \"task\"\n"),
            };
        };
        return runFirstRunnableSpec(allocator, io, specs, repo_path, worktree_root, verify_commands, task, hasFlag(args, "--no-apply"), optionValue(args, "--agents"), optionValue(args, "--mode"), optionValue(args, "--depth"), optionValue(args, "--planner"), reviewFromArgs(args), optionValue(args, "--cooldown-agent"), hasFlag(args, "--explain-routing"), true, optionValue(args, "--job-id"));
    }
    // run <task> is the explicit subcommand form of the positional task.
    // It is the recommended entry point for coding agents because it
    // avoids any ambiguity about what is a flag and what is the task.
    if (std.mem.eql(u8, args[1], "run")) {
        const task = subcommandTask(args[2..]) orelse {
            return .{
                .code = exit_usage,
                .text = try allocator.dupe(u8, "usage: openfugu run \"task\"\n"),
            };
        };
        return runFirstRunnableSpec(allocator, io, specs, repo_path, worktree_root, verify_commands, task, hasFlag(args, "--no-apply"), optionValue(args, "--agents"), optionValue(args, "--mode"), optionValue(args, "--depth"), optionValue(args, "--planner"), reviewFromArgs(args), optionValue(args, "--cooldown-agent"), hasFlag(args, "--explain-routing"), hasFlag(args, "--route-only"), optionValue(args, "--job-id"));
    }
    // submit <task> spawns a detached `openfugu run --job-id=<id> "task"`
    // child and returns immediately with the job id. The child updates
    // the job file at start and completion so poll/wait can read status
    // without a daemon.
    if (std.mem.eql(u8, args[1], "submit")) {
        return submitJob(allocator, io, args, repo_path);
    }
    // poll <job-id> reads the job file and prints its current status.
    if (std.mem.eql(u8, args[1], "poll")) {
        if (args.len < 3) {
            return .{
                .code = exit_usage,
                .text = try allocator.dupe(u8, "usage: openfugu poll <job-id>\n"),
            };
        }
        return pollJob(allocator, io, args[2]);
    }
    // wait <job-id> blocks until the job reaches a terminal status, then
    // prints the final status. Exits with the job's exit code when known.
    if (std.mem.eql(u8, args[1], "wait")) {
        if (args.len < 3) {
            return .{
                .code = exit_usage,
                .text = try allocator.dupe(u8, "usage: openfugu wait <job-id>\n"),
            };
        }
        return waitJob(allocator, io, args[2]);
    }
    // jobs lists all known job ids and their statuses.
    if (std.mem.eql(u8, args[1], "jobs")) {
        return listJobs(allocator, io);
    }
    if (std.mem.eql(u8, args[1], "doctor") or std.mem.eql(u8, args[1], "agents")) {
        const reports = try collectReports(allocator, io, specs);
        defer probe.freeReports(allocator, reports);
        if (std.mem.eql(u8, args[1], "doctor")) {
            return .{
                .code = exit_ok,
                .text = try doctor.render(allocator, .{
                    .config_ok = true,
                    .git_ok = gitOk(allocator, io),
                    .worktree_ok = worktreeOk(allocator, io),
                    .subscription_only = true,
                    .agents = reports,
                }),
            };
        }
        return .{ .code = exit_ok, .text = try renderAgents(allocator, reports) };
    }
    if (try taskText(args)) |task| {
        return runFirstRunnableSpec(allocator, io, specs, repo_path, worktree_root, verify_commands, task, hasFlag(args, "--no-apply"), optionValue(args, "--agents"), optionValue(args, "--mode"), optionValue(args, "--depth"), optionValue(args, "--planner"), reviewFromArgs(args), optionValue(args, "--cooldown-agent"), hasFlag(args, "--explain-routing"), hasFlag(args, "--route-only"), optionValue(args, "--job-id"));
    }
    return run(allocator, args);
}

pub fn runAlloc(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    if (args.len <= 1) return std.fmt.allocPrint(allocator, "openfugu {s}\n", .{config.version});

    const cmd = args[1];
    if (isHelp(cmd)) return helpText(allocator);
    if (std.mem.eql(u8, cmd, "plan")) {
        const plan_args = try parsePlanArgs(args);
        var plan = try heuristic.plan(allocator, .{ .request = plan_args.request });
        defer planner.deinitPlan(allocator, &plan);
        if (std.mem.eql(u8, plan_args.backend, "subscription-agent")) {
            return std.fmt.allocPrint(allocator, "planner=subscription-agent fallback=heuristic topology={s} quota=0\n", .{@tagName(plan.topology)});
        }
        if (std.mem.eql(u8, plan_args.backend, "capability")) {
            var cap_plan = try @import("planner/capability.zig").plan(allocator, .{ .request = plan_args.request });
            defer planner.deinitPlan(allocator, &cap_plan);
            return std.fmt.allocPrint(allocator, "planner=capability topology={s} quota=0\n", .{@tagName(cap_plan.topology)});
        }
        return std.fmt.allocPrint(allocator, "planner=heuristic topology={s} quota=0\n", .{@tagName(plan.topology)});
    }
    if (std.mem.eql(u8, cmd, "doctor")) {
        return doctor.render(allocator, .{
            .config_ok = true,
            .git_ok = true,
            .worktree_ok = true,
            .subscription_only = true,
            .agents = defaultAgentReports(),
        });
    }
    if (std.mem.eql(u8, cmd, "agents") or std.mem.eql(u8, cmd, "list-agents")) {
        return renderAgents(allocator, defaultAgentReports());
    }
    if (std.mem.eql(u8, cmd, "status")) {
        const summary = usage.Summary{};
        return std.fmt.allocPrint(allocator, "agents=3 runnable=0 ledger_calls={d} successes={d} failures={d} rate_limits={d}\n  claude compatibility=unknown auth=unknown runnable=false\n  codex compatibility=unknown auth=unknown runnable=false\n  agy compatibility=unknown auth=unknown runnable=false\n", .{
            summary.calls,
            summary.successes,
            summary.failures,
            summary.rate_limits,
        });
    }
    if (std.mem.eql(u8, cmd, "usage")) {
        const events = [_]usage.Event{.{ .agent = "fixture", .reported_tokens = null, .rate_limited = false, .ok = true }};
        const summary = usage.summarize(&events);
        return std.fmt.allocPrint(allocator, "calls={d} reported={d} unavailable={d} rate_limits={d}\n", .{ summary.calls, summary.reported_tokens, summary.unavailable_tokens, summary.rate_limits });
    }
    if (std.mem.eql(u8, cmd, "replay")) {
        if (args.len < 3) return error.InvalidArgs;
        return replay.fixture(allocator, args[2]);
    }

    if (try taskText(args) != null) {
        return allocator.dupe(u8, "no subscription-compatible agent available; run `openfugu doctor` for details\n");
    }
    return error.InvalidArgs;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub const InteractiveInput = union(enum) {
    empty,
    quit,
    clear,
    clear_history,
    history,
    doctor,
    agents,
    usage,
    ledger,
    where_,
    worktrees,
    git,
    changed,
    remote,
    branch,
    branches,
    tags,
    describe,
    log,
    diff,
    staged,
    staged_patch,
    patch,
    ci,
    watch_ci,
    pr,
    issues,
    verify,
    build,
    test_,
    fmt,
    check,
    cancel,
    help,
    status,
    reset_routing,
    dry_run,
    no_apply,
    apply,
    last,
    rerun,
    fetch,
    pull,
    push,
    push_force_with_lease,
    stash,
    stashes,
    stash_show,
    stash_patch,
    stash_pop,
    save: []const u8,
    stage: []const u8,
    unstage: []const u8,
    commit: []const u8,
    commit_amend: []const u8,
    commit_amend_no_edit,
    switch_branch: []const u8,
    new_branch: []const u8,
    show: []const u8,
    issue: []const u8,
    pr_view: []const u8,
    pr_checkout: []const u8,
    run: []const u8,
    rg: []const u8,
    todo,
    ls: []const u8,
    files: []const u8,
    cwd: []const u8,
    load: []const u8,
    open: []const u8,
    head: []const u8,
    tail: []const u8,
    plan_last,
    plan: []const u8,
    route_last,
    route: []const u8,
    replay: []const u8,
    agent: []const u8,
    mode: []const u8,
    planner: []const u8,
    unknown_command,
    task: []const u8,
};

pub fn interactiveInput(input: []const u8) InteractiveInput {
    const task = std.mem.trim(u8, input, " \t\r\n");
    if (task.len == 0) return .empty;
    if (std.mem.eql(u8, task, ":quit") or std.mem.eql(u8, task, ":exit")) return .quit;
    if (std.mem.eql(u8, task, ":clear")) return .clear;
    if (std.mem.eql(u8, task, ":clear-history")) return .clear_history;
    if (std.mem.eql(u8, task, ":history")) return .history;
    if (std.mem.eql(u8, task, ":doctor")) return .doctor;
    if (std.mem.eql(u8, task, ":agents")) return .agents;
    if (std.mem.eql(u8, task, ":usage")) return .usage;
    if (std.mem.eql(u8, task, ":ledger")) return .ledger;
    if (std.mem.eql(u8, task, ":where") or std.mem.eql(u8, task, ":pwd")) return .where_;
    if (std.mem.eql(u8, task, ":worktrees")) return .worktrees;
    if (std.mem.eql(u8, task, ":git")) return .git;
    if (std.mem.eql(u8, task, ":changed")) return .changed;
    if (std.mem.eql(u8, task, ":remote")) return .remote;
    if (std.mem.eql(u8, task, ":branch")) return .branch;
    if (std.mem.eql(u8, task, ":branches")) return .branches;
    if (std.mem.eql(u8, task, ":tags")) return .tags;
    if (std.mem.eql(u8, task, ":describe")) return .describe;
    if (std.mem.eql(u8, task, ":log")) return .log;
    if (std.mem.eql(u8, task, ":diff")) return .diff;
    if (std.mem.eql(u8, task, ":staged")) return .staged;
    if (std.mem.eql(u8, task, ":staged-patch")) return .staged_patch;
    if (std.mem.eql(u8, task, ":patch")) return .patch;
    if (std.mem.eql(u8, task, ":ci")) return .ci;
    if (std.mem.eql(u8, task, ":watch-ci")) return .watch_ci;
    if (std.mem.eql(u8, task, ":pr")) return .pr;
    if (std.mem.eql(u8, task, ":issues")) return .issues;
    if (std.mem.eql(u8, task, ":verify")) return .verify;
    if (std.mem.eql(u8, task, ":build")) return .build;
    if (std.mem.eql(u8, task, ":test")) return .test_;
    if (std.mem.eql(u8, task, ":fmt")) return .fmt;
    if (std.mem.eql(u8, task, ":check")) return .check;
    if (std.mem.eql(u8, task, ":cancel")) return .cancel;
    if (std.mem.eql(u8, task, ":help")) return .help;
    if (std.mem.eql(u8, task, ":status")) return .status;
    if (std.mem.eql(u8, task, ":reset-routing")) return .reset_routing;
    if (std.mem.eql(u8, task, ":dry-run")) return .dry_run;
    if (std.mem.eql(u8, task, ":no-apply")) return .no_apply;
    if (std.mem.eql(u8, task, ":apply")) return .apply;
    if (std.mem.eql(u8, task, ":last")) return .last;
    if (std.mem.eql(u8, task, ":rerun")) return .rerun;
    if (std.mem.eql(u8, task, ":fetch")) return .fetch;
    if (std.mem.eql(u8, task, ":pull")) return .pull;
    if (std.mem.eql(u8, task, ":push")) return .push;
    if (std.mem.eql(u8, task, ":push-force-with-lease")) return .push_force_with_lease;
    if (std.mem.eql(u8, task, ":stash")) return .stash;
    if (std.mem.eql(u8, task, ":stashes")) return .stashes;
    if (std.mem.eql(u8, task, ":stash-show")) return .stash_show;
    if (std.mem.eql(u8, task, ":stash-patch")) return .stash_patch;
    if (std.mem.eql(u8, task, ":stash-pop")) return .stash_pop;
    if (commandValue(task, ":save")) |value| return .{ .save = value };
    if (commandValue(task, ":stage")) |value| return .{ .stage = value };
    if (commandValue(task, ":unstage")) |value| return .{ .unstage = value };
    if (std.mem.eql(u8, task, ":commit-amend-no-edit")) return .commit_amend_no_edit;
    if (commandValue(task, ":commit-amend")) |value| return .{ .commit_amend = value };
    if (commandValue(task, ":commit")) |value| return .{ .commit = value };
    if (commandValue(task, ":switch")) |value| return .{ .switch_branch = value };
    if (commandValue(task, ":new-branch")) |value| return .{ .new_branch = value };
    if (commandValue(task, ":show")) |value| return .{ .show = value };
    if (commandValue(task, ":issue")) |value| return .{ .issue = value };
    if (commandValue(task, ":pr-checkout")) |value| return .{ .pr_checkout = value };
    if (commandValue(task, ":pr")) |value| return .{ .pr_view = value };
    if (commandValue(task, ":run")) |value| return .{ .run = value };
    if (commandValue(task, ":rg")) |value| return .{ .rg = value };
    if (std.mem.eql(u8, task, ":todo")) return .todo;
    if (std.mem.eql(u8, task, ":ls")) return .{ .ls = "." };
    if (commandValue(task, ":ls")) |value| return .{ .ls = value };
    if (std.mem.eql(u8, task, ":files")) return .{ .files = "." };
    if (commandValue(task, ":files")) |value| return .{ .files = value };
    if (commandValue(task, ":cd")) |value| return .{ .cwd = value };
    if (commandValue(task, ":cwd")) |value| return .{ .cwd = value };
    if (commandValue(task, ":load")) |value| return .{ .load = value };
    if (commandValue(task, ":open")) |value| return .{ .open = value };
    if (commandValue(task, ":head")) |value| return .{ .head = value };
    if (commandValue(task, ":tail")) |value| return .{ .tail = value };
    if (std.mem.eql(u8, task, ":plan")) return .plan_last;
    if (commandValue(task, ":plan")) |value| return .{ .plan = value };
    if (std.mem.eql(u8, task, ":route")) return .route_last;
    if (commandValue(task, ":route")) |value| return .{ .route = value };
    if (commandValue(task, ":replay")) |value| return .{ .replay = value };
    if (commandValue(task, ":agent")) |value| return .{ .agent = value };
    if (commandValue(task, ":mode")) |value| return .{ .mode = value };
    if (commandValue(task, ":planner")) |value| return .{ .planner = value };
    if (std.mem.startsWith(u8, task, ":")) return .unknown_command;
    return .{ .task = task };
}

fn commandValue(input: []const u8, command: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, input, command)) return null;
    if (input.len == command.len) return null;
    if (input[command.len] != ' ') return null;
    const value = std.mem.trim(u8, input[command.len + 1 ..], " \t");
    if (value.len == 0) return null;
    return value;
}

pub const OpenSpec = struct {
    path: []const u8,
    line: ?usize = null,
};

pub fn parseOpenSpec(input: []const u8) OpenSpec {
    const colon = std.mem.lastIndexOfScalar(u8, input, ':') orelse return .{ .path = input };
    if (colon == 0 or colon + 1 == input.len) return .{ .path = input };
    const line = std.fmt.parseInt(usize, input[colon + 1 ..], 10) catch return .{ .path = input };
    if (line == 0) return .{ .path = input };
    return .{ .path = input[0..colon], .line = line };
}

pub fn numberedLines(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return numberedLinesAround(allocator, text, 1, std.math.maxInt(usize));
}

pub fn numberedLinesAround(allocator: std.mem.Allocator, text: []const u8, first_line: usize, max_lines: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var line_no: usize = 1;
    var emitted: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        if (line_no < first_line) {
            line_no += 1;
            continue;
        }
        if (emitted >= max_lines) break;
        try out.print(allocator, "{d:4} | {s}\n", .{ line_no, line });
        line_no += 1;
        emitted += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn helpText(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\Usage: openfugu [subcommand] [options] "task"
        \\       openfugu
        \\
        \\Run without arguments to start the interactive TUI.
        \\
        \\Subcommands (recommended for coding agents):
        \\  openfugu route "task"        print routing decision without running
        \\  openfugu run "task"          route and execute the task
        \\  openfugu submit "task"       fire a task and return immediately (async)
        \\  openfugu poll <job-id>       check status of a submitted job
        \\  openfugu wait <job-id>       block until a submitted job finishes
        \\  openfugu jobs                list all known job ids and statuses
        \\  openfugu list-agents         list detected agents and runnability
        \\  openfugu status              summary of agents and ledger health
        \\  openfugu plan [--planner P] "task"   preview workflow plan
        \\  openfugu doctor              setup and dependency diagnostics
        \\  openfugu agents              list runnable agents (alias: list-agents)
        \\  openfugu usage [--since 1d]  routing ledger usage summary
        \\  openfugu replay <run-id>     show ledger replay for a run
        \\
        \\Options (both --flag value and --flag=value are accepted):
        \\  --no-apply             run without applying the candidate patch
        \\  --explain-routing      print router score and selected agent
        \\  --route-only           print router score without executing
        \\  --agents <name>        restrict execution to one agent
        \\                         aliases: claude, claudecode, claude-code,
        \\                                   codex, agy, antigravity
        \\  --mode <name>          auto, single, race, ensemble
        \\  --planner <name>       heuristic, subscription-agent, capability
        \\  --depth <n>            execution depth override
        \\  --cooldown-agent <name> exclude an agent from this run
        \\
        \\Exit codes:
        \\  0   ok
        \\  2   usage error
        \\  3   no subscription-compatible agent available
        \\  4   budget exhausted
        \\  5   verification failed
        \\  6   workspace error
        \\  7   planner error
        \\  8   compatibility error
        \\  130 canceled (SIGINT)
        \\
        \\Coding-agent tip: run `openfugu route "task"` first to inspect the
        \\routing decision cheaply, then `openfugu run "task"` to execute.
        \\
    );
}

fn taskText(args: []const []const u8) !?[]const u8 {
    if (args.len <= 1) return null;
    const cmd = args[1];
    if (isHelp(cmd)) return null;
    if (std.mem.eql(u8, cmd, "plan")) return null;
    if (std.mem.eql(u8, cmd, "doctor")) return null;
    if (std.mem.eql(u8, cmd, "agents")) return null;
    if (std.mem.eql(u8, cmd, "list-agents")) return null;
    if (std.mem.eql(u8, cmd, "route")) return null;
    if (std.mem.eql(u8, cmd, "run")) return null;
    if (std.mem.eql(u8, cmd, "submit")) return null;
    if (std.mem.eql(u8, cmd, "poll")) return null;
    if (std.mem.eql(u8, cmd, "wait")) return null;
    if (std.mem.eql(u8, cmd, "jobs")) return null;
    if (std.mem.eql(u8, cmd, "status")) return null;
    if (std.mem.eql(u8, cmd, "usage")) return null;
    if (std.mem.eql(u8, cmd, "replay")) return null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--subscription-only") or
            std.mem.eql(u8, arg, "--no-apply") or
            std.mem.eql(u8, arg, "--require-model-review") or
            std.mem.eql(u8, arg, "--reject-model-review") or
            std.mem.eql(u8, arg, "--route-only") or
            std.mem.eql(u8, arg, "--explain-routing")) continue;
        if (isInlineValue(arg)) {
            // --flag=value: no separate value token to consume.
            continue;
        }
        if (takesValue(arg)) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            try validateOptionValue(arg, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArgs;
        return arg;
    }
    return error.InvalidArgs;
}

/// isInlineValue reports whether arg is a --flag=value form for a flag
/// we recognise. We accept both the inline form and the two-token form,
/// so coding agents that prefer --flag=value can use it directly.
fn isInlineValue(arg: []const u8) bool {
    const known = [_][]const u8{ "--mode", "--agents", "--planner", "--depth", "--cooldown-agent", "--job-id" };
    for (known) |flag| {
        if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len and arg[flag.len] == '=') return true;
    }
    return false;
}

fn inlineValue(arg: []const u8) ?[]const u8 {
    const known = [_][]const u8{ "--mode", "--agents", "--planner", "--depth", "--cooldown-agent", "--job-id" };
    for (known) |flag| {
        if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len and arg[flag.len] == '=') {
            return arg[flag.len + 1 ..];
        }
    }
    return null;
}

fn takesValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--mode") or
        std.mem.eql(u8, arg, "--agents") or
        std.mem.eql(u8, arg, "--planner") or
        std.mem.eql(u8, arg, "--depth") or
        std.mem.eql(u8, arg, "--cooldown-agent") or
        std.mem.eql(u8, arg, "--job-id");
}

fn validateOptionValue(flag: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, flag, "--mode") and !validMode(value)) return error.InvalidArgs;
    if (std.mem.eql(u8, flag, "--planner") and !validPlanner(value)) return error.InvalidArgs;
}

fn validMode(value: []const u8) bool {
    return std.mem.eql(u8, value, "auto") or
        std.mem.eql(u8, value, "single") or
        std.mem.eql(u8, value, "race") or
        std.mem.eql(u8, value, "ensemble");
}

fn validPlanner(value: []const u8) bool {
    return std.mem.eql(u8, value, "heuristic") or
        std.mem.eql(u8, value, "subscription-agent") or
        std.mem.eql(u8, value, "capability");
}

const PlanArgs = struct {
    backend: []const u8,
    request: []const u8,
};

fn parsePlanArgs(args: []const []const u8) !PlanArgs {
    if (args.len < 3) return error.InvalidArgs;
    if (std.mem.eql(u8, args[2], "--planner")) {
        if (args.len < 5) return error.InvalidArgs;
        if (!validPlanner(args[3])) return error.InvalidArgs;
        return .{ .backend = args[3], .request = args[4] };
    }
    if (std.mem.startsWith(u8, args[2], "--planner=")) {
        const value = args[2]["--planner=".len..];
        if (!validPlanner(value)) return error.InvalidArgs;
        if (args.len < 4) return error.InvalidArgs;
        return .{ .backend = value, .request = args[3] };
    }
    return .{ .backend = "subscription-agent", .request = args[2] };
}

fn defaultAgentReports() []const probe.AgentReport {
    return &.{
        .{ .name = "claude", .compatibility = .unknown, .auth = .unknown, .runnable = false },
        .{ .name = "codex", .compatibility = .unknown, .auth = .unknown, .runnable = false },
        .{ .name = "agy", .compatibility = .unknown, .auth = .unknown, .runnable = false },
    };
}

fn defaultDetectSpecs() [3]probe.DetectSpec {
    const subscription = config.Config.default().subscription;
    return .{
        .{
            .name = "claude",
            .version_argv = &claude_version_argv,
            .auth_argv = &claude_auth_argv,
            .supported_version = "2.",
            .profile = claude_code.profileForVersion("2."),
            .subscription = subscription,
        },
        .{
            .name = "codex",
            .version_argv = &codex_version_argv,
            .auth_argv = &codex_auth_argv,
            .supported_version = "codex-cli 0.141.",
            .profile = codex.profileForVersion("codex-cli 0.141."),
            .subscription = subscription,
        },
        .{
            .name = "agy",
            .version_argv = &agy_version_argv,
            .auth_argv = &agy_auth_argv,
            .auth_success_means_subscription = true,
            .auth_timeout_ms = 15000,
            .supported_version = "1.0.",
            .profile = antigravity.profileForVersion("1.0."),
            .subscription = subscription,
        },
    };
}

fn renderAgents(allocator: std.mem.Allocator, agents: []const probe.AgentReport) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (agents) |agent| {
        try out.print(allocator, "{s} compatibility={s} auth={s} runnable={}\n", .{
            agent.name,
            @tagName(agent.compatibility),
            @tagName(agent.auth),
            agent.runnable,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn countRunnable(reports: []const probe.AgentReport) usize {
    var n: usize = 0;
    for (reports) |agent| if (agent.runnable) {
        n += 1;
    };
    return n;
}

/// subcommandTask extracts the first non-flag token from the args that
/// follow a subcommand like `route` or `run`. It skips flags and their
/// inline (--flag=value) or two-token (--flag value) values so the
/// task text is identified correctly regardless of flag position.
fn subcommandTask(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--subscription-only") or
            std.mem.eql(u8, arg, "--no-apply") or
            std.mem.eql(u8, arg, "--require-model-review") or
            std.mem.eql(u8, arg, "--reject-model-review") or
            std.mem.eql(u8, arg, "--route-only") or
            std.mem.eql(u8, arg, "--explain-routing")) continue;
        if (isInlineValue(arg)) continue;
        if (takesValue(arg)) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) continue;
        return arg;
    }
    return null;
}

fn collectReports(allocator: std.mem.Allocator, io: std.Io, specs: []const probe.DetectSpec) ![]probe.AgentReport {
    const reports = try allocator.alloc(probe.AgentReport, specs.len);
    errdefer allocator.free(reports);
    for (specs, 0..) |spec, i| {
        reports[i] = try probe.detect(allocator, io, spec);
    }
    return reports;
}

fn gitOk(allocator: std.mem.Allocator, io: std.Io) bool {
    var result = runner.run(allocator, io, .{
        .executable = "git",
        .argv = &.{ "git", "rev-parse", "--is-inside-work-tree" },
        .cwd = ".",
        .timeout_ms = 1000,
    }) catch return false;
    defer result.deinit(allocator);
    return result.exit_code == 0 and std.mem.indexOf(u8, result.stdout_tail, "true") != null;
}

fn worktreeOk(allocator: std.mem.Allocator, io: std.Io) bool {
    var result = runner.run(allocator, io, .{
        .executable = "git",
        .argv = &.{ "git", "worktree", "list", "--porcelain" },
        .cwd = ".",
        .timeout_ms = 1000,
    }) catch return false;
    defer result.deinit(allocator);
    return result.exit_code == 0;
}

fn runFirstRunnableSpec(
    allocator: std.mem.Allocator,
    io: std.Io,
    specs: []const probe.DetectSpec,
    repo_path: []const u8,
    worktree_root: []const u8,
    verify_commands: []const verify.Command,
    task_text: []const u8,
    no_apply: bool,
    agents_filter: ?[]const u8,
    mode: ?[]const u8,
    depth: ?[]const u8,
    planner_backend: ?[]const u8,
    review: model_review.Review,
    cooldown_filter: ?[]const u8,
    explain_routing: bool,
    route_only: bool,
    job_id: ?[]const u8,
) !Result {
    // When invoked via `submit`, the child is given --job-id=<id>. We
    // update the job file at start and completion so poll/wait work
    // without a daemon.
    const has_job = job_id != null;
    if (has_job) {
        jobs.write(allocator, io, .{
            .id = job_id.?,
            .status = .running,
            .task = task_text,
            .started_ms = nowMs(io),
        }) catch {};
    }
    // errdefer at function scope so it fires on any error return from
    // this point onward, regardless of which block raised the error.
    errdefer {
        if (has_job) {
            finishJob(allocator, io, job_id.?, exit_planner, "", "heuristic", "unknown", "error before completion") catch {};
        }
    }
    try std.Io.Dir.cwd().createDirPath(io, worktree_root);
    var candidates = try allocator.alloc(RoutingCandidate, specs.len);
    defer allocator.free(candidates);
    var candidate_count: usize = 0;
    var kind = policy.classifyTask(task_text);
    var preferred_agent: policy.PreferredAgent = .none;
    var router_name: []const u8 = "heuristic";
    for (specs) |spec| {
        if (!agentAllowed(agents_filter, spec.name)) continue;
        if (agentListed(cooldown_filter, spec.name)) continue;
        var report_value = try probe.detect(allocator, io, spec);
        if (!report_value.runnable) {
            report_value.deinit(allocator);
            continue;
        }
        candidates[candidate_count] = .{
            .spec = spec,
            .report = report_value,
            .score = 0,
        };
        candidate_count += 1;
    }
    defer freeRoutingCandidates(allocator, candidates[0..candidate_count]);
    const effective_planner = planner_backend orelse "subscription-agent";
    if (std.mem.eql(u8, effective_planner, "subscription-agent")) {
        if (try fastRouterHint(allocator, io, repo_path, task_text, candidates[0..candidate_count])) |hint| {
            if (hint.kind) |router_kind| kind = router_kind;
            preferred_agent = hint.preferred_agent;
            router_name = "subscription-agent";
        }
    } else if (std.mem.eql(u8, effective_planner, "capability")) {
        router_name = "capability";
    } else {
        router_name = "heuristic";
    }
    for (candidates[0..candidate_count]) |*candidate| {
        const ledger_path = try runLedgerPath(allocator, worktree_root);
        defer allocator.free(ledger_path);
        const stats = try ledgerStatsForAgent(allocator, io, ledger_path, candidate.report.name);
        candidate.stats = stats;
        candidate.score = policy.scoreAgent(.{
            .id = candidate.report.name,
            .profile_name = candidate.spec.profile.name,
            .kind = kind,
            .preferred_agent = preferred_agent,
            .calls = stats.calls,
            .successes = stats.successes,
            .failures = stats.failures,
            .capability = candidate.spec.profile.capability,
        });
    }
    sortRoutingCandidates(candidates[0..candidate_count]);

    if (route_only) {
        if (candidate_count == 0) {
            return .{
                .code = exit_no_agent,
                .text = try allocator.dupe(u8, "no subscription-compatible agent available; run `openfugu doctor` for details\n"),
            };
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const header = try std.fmt.allocPrint(allocator,
            \\router={s}
            \\route={s}
            \\preferred={s}
            \\
        , .{
            router_name,
            @tagName(kind),
            @tagName(preferred_agent),
        });
        defer allocator.free(header);
        try out.appendSlice(allocator, header);
        for (candidates[0..candidate_count]) |candidate| {
            const line = try std.fmt.allocPrint(allocator, "candidate agent={s} score={d} profile={s} calls={d} successes={d} failures={d}\n", .{
                candidate.report.name,
                candidate.score,
                candidate.spec.profile.name,
                candidate.stats.calls,
                candidate.stats.successes,
                candidate.stats.failures,
            });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
        const footer = try std.fmt.allocPrint(allocator,
            \\selected={s}
            \\execute=false
            \\
        , .{candidates[0].report.name});
        defer allocator.free(footer);
        try out.appendSlice(allocator, footer);
        return .{ .code = exit_ok, .text = try out.toOwnedSlice(allocator) };
    }

    for (candidates[0..candidate_count]) |*candidate| {
        const candidate_path = try candidateWorktreePath(allocator, io, worktree_root, candidate.report.name);
        defer allocator.free(candidate_path);
        var owned_invocation = try invocationForSpec(allocator, candidate.spec, task_text, candidate_path);
        defer owned_invocation.deinit(allocator);
        var summary = try conductor.runInvocationSingle(allocator, .{
            .repo_path = repo_path,
            .worktree_root = worktree_root,
            .run_id = "cli",
            .candidate_id = "candidate",
            .agent_id = candidate.report.name,
            .invocation = owned_invocation.value,
            .timeout_ms = 180000,
            .io = io,
            .verify_commands = verify_commands,
            .apply = !no_apply,
            .model_review = review,
        });
        defer summary.deinit(allocator);
        const ledger_path = try runLedgerPath(allocator, worktree_root);
        defer allocator.free(ledger_path);
        try ledger.append(allocator, io, ledger_path, .{
            .run_id = "cli",
            .agent = candidate.report.name,
            .content = task_text,
            .include_content = false,
            .verification_passed = summary.candidate_verification.passed,
            .accepted = summary.accepted,
            .applied = summary.applied,
            .reverified = summary.reverified,
        });

        const code = if (summary.accepted and (no_apply or (summary.applied and summary.reverified))) exit_ok else exit_verify;
        if (code != exit_ok and continuesAfterFailure(mode, depth)) continue;
        if (has_job) try finishJob(allocator, io, job_id.?, code, candidate.report.name, router_name, @tagName(kind), summary_text(summary));
        if (explain_routing) {
            return .{
                .code = code,
                .text = try std.fmt.allocPrint(allocator, "router={s} route={s} preferred={s} score={d} agent={s} accepted={} applied={} reverified={}\n", .{
                    router_name,
                    @tagName(kind),
                    @tagName(preferred_agent),
                    candidate.score,
                    candidate.report.name,
                    summary.accepted,
                    summary.applied,
                    summary.reverified,
                }),
            };
        }
        return .{
            .code = code,
            .text = try std.fmt.allocPrint(allocator, "router={s} route={s} agent={s} accepted={} applied={} reverified={}\n", .{
                router_name,
                @tagName(kind),
                candidate.report.name,
                summary.accepted,
                summary.applied,
                summary.reverified,
            }),
        };
    }
    if (candidate_count != 0) {
        if (has_job) try finishJob(allocator, io, job_id.?, exit_verify, "", router_name, @tagName(kind), "no candidate passed verification");
        return .{
            .code = exit_verify,
            .text = try allocator.dupe(u8, "no candidate passed verification\n"),
        };
    }
    if (has_job) try finishJob(allocator, io, job_id.?, exit_no_agent, "", router_name, @tagName(kind), "no subscription-compatible agent available");
    return .{
        .code = exit_no_agent,
        .text = try allocator.dupe(u8, "no subscription-compatible agent available; run `openfugu doctor` for details\n"),
    };
}

fn summary_text(summary: conductor.RunSummary) []const u8 {
    if (summary.accepted and summary.applied and summary.reverified) return "accepted applied reverified";
    if (summary.accepted) return "accepted not-applied";
    return "verification failed";
}

fn finishJob(
    allocator: std.mem.Allocator,
    io: std.Io,
    job_id: []const u8,
    exit_code: u8,
    agent: []const u8,
    router: []const u8,
    route: []const u8,
    summary: []const u8,
) !void {
    jobs.write(allocator, io, .{
        .id = job_id,
        .status = if (exit_code == exit_ok) .ok else .failed,
        .agent = agent,
        .router = router,
        .route = route,
        .exit_code = exit_code,
        .ended_ms = nowMs(io),
        .summary = summary,
    }) catch {};
}

fn sortRoutingCandidates(candidates: []RoutingCandidate) void {
    var i: usize = 0;
    while (i < candidates.len) : (i += 1) {
        var best = i;
        var j = i + 1;
        while (j < candidates.len) : (j += 1) {
            if (candidates[j].score > candidates[best].score) best = j;
        }
        if (best != i) std.mem.swap(RoutingCandidate, &candidates[i], &candidates[best]);
    }
}

fn freeRoutingCandidates(allocator: std.mem.Allocator, candidates: []RoutingCandidate) void {
    for (candidates) |*candidate| candidate.report.deinit(allocator);
}

fn fastRouterHint(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    task_text: []const u8,
    candidates: []const RoutingCandidate,
) !?policy.RouterHint {
    // Try each candidate that exposes a dedicated router argv first.
    // These are cheaper and more deterministic than a model prompt.
    for (candidates) |candidate| {
        if (candidate.spec.router_argv) |argv| {
            var result = try runner.run(allocator, io, .{
                .executable = argv[0],
                .argv = argv,
                .cwd = repo_path,
                .stdout_tail_bytes = 4096,
                .stderr_tail_bytes = 4096,
                .timeout_ms = 30000,
            });
            defer result.deinit(allocator);
            if (result.exit_code == 0) {
                if (policy.parseRouterHint(result.stdout_tail)) |hint| return hint;
            }
        }
    }
    // Fall back to a structured-output model prompt. Try up to two
    // candidates so a single agent's malformed output does not lose the
    // router hint entirely.
    var attempts: usize = 0;
    for (candidates) |candidate| {
        if (!candidate.report.structured_output) continue;
        if (attempts >= 2) break;
        const prompt = try fastRouterPrompt(allocator, task_text);
        defer allocator.free(prompt);
        const task = types.Task{
            .id = "fast-router",
            .role = .thinker,
            .intent = .plan,
            .instruction = prompt,
            .worktree_path = repo_path,
            .context = "",
            .target_files = &.{},
            .timeout_ms = 30000,
            .read_only = true,
        };
        var invocation = routerInvocationForSpec(allocator, candidate.spec, task) catch continue;
        defer invocation.deinit(allocator);
        var result = runner.runInvocation(allocator, io, invocation.value, 30000) catch continue;
        defer result.deinit(allocator);
        attempts += 1;
        if (result.exit_code == 0) {
            if (policy.parseRouterHint(result.stdout_tail)) |hint| return hint;
        }
    }
    return null;
}

fn fastRouterPrompt(allocator: std.mem.Allocator, task_text: []const u8) ![]u8 {
    // The prompt is deliberately strict: it demands a single JSON object
    // with exactly two string fields and nothing else. This makes the
    // parser's job easier and reduces the chance of prose leaking into
    // the output. Enumerating valid values tells the model the exact
    // vocabulary we accept, so a miss is unambiguous.
    return std.fmt.allocPrint(
        allocator,
        "Route this coding task. Return ONLY a single JSON object on one line, no prose, no markdown fences. " ++
            "Schema: {{\"task_kind\": string, \"preferred_agent\": string}}. " ++
            "task_kind must be one of: general, bugfix, test_fix, refactor, terminal, review, frontend, broad. " ++
            "preferred_agent must be one of: claude, codex, agy. " ++
            "Do not include any other fields. Task: {s}",
        .{task_text},
    );
}

fn routerInvocationForSpec(allocator: std.mem.Allocator, spec: probe.DetectSpec, task: types.Task) !adapter.OwnedInvocation {
    if (std.mem.eql(u8, spec.profile.name, "claude-code")) return claude_code.buildInvocation(allocator, .supported_1, task);
    if (std.mem.eql(u8, spec.profile.name, "codex")) return codex.buildInvocation(allocator, .supported_1, task);
    if (std.mem.eql(u8, spec.profile.name, "antigravity")) return antigravity.buildInvocation(allocator, .degraded_text, task);
    return error.UnsupportedProfile;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn reviewFromArgs(args: []const []const u8) model_review.Review {
    return .{
        .required = hasFlag(args, "--require-model-review"),
        .rejected = hasFlag(args, "--reject-model-review"),
        .summary = if (hasFlag(args, "--reject-model-review")) "rejected by model review" else "",
    };
}

fn optionValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    // --flag=value inline form takes precedence over the two-token form.
    const inline_form = std.fmt.allocPrint(std.heap.page_allocator, "{s}=", .{flag}) catch return null;
    defer std.heap.page_allocator.free(inline_form);
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, inline_form)) {
            const value = arg[inline_form.len..];
            if (value.len != 0) return value;
        }
    }
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

fn agentAllowed(filter: ?[]const u8, name: []const u8) bool {
    const text = filter orelse return true;
    return agentListed(text, name);
}

fn agentListed(filter: ?[]const u8, name: []const u8) bool {
    const text = filter orelse return false;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (std.mem.eql(u8, part, name)) return true;
        if (std.mem.eql(u8, part, "antigravity") and std.mem.eql(u8, name, "agy")) return true;
        if ((std.mem.eql(u8, part, "claudecode") or std.mem.eql(u8, part, "claude-code")) and std.mem.eql(u8, name, "claude")) return true;
    }
    return false;
}

fn continuesAfterFailure(mode: ?[]const u8, depth: ?[]const u8) bool {
    if (depth) |value| {
        if (std.mem.eql(u8, value, "0")) return false;
    }
    const value = mode orelse return false;
    return std.mem.eql(u8, value, "race") or std.mem.eql(u8, value, "ensemble");
}

fn runLedgerPath(allocator: std.mem.Allocator, worktree_root: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(worktree_root) orelse ".";
    return std.fs.path.join(allocator, &.{ parent, "ledger.jsonl" });
}

fn ledgerStatsForAgent(allocator: std.mem.Allocator, io: std.Io, path: []const u8, agent: []const u8) !LedgerStats {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return .{};
    defer allocator.free(text);
    const needle = try std.fmt.allocPrint(allocator, "\"agent\":\"{s}\"", .{agent});
    defer allocator.free(needle);
    var out: LedgerStats = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        out.calls += 1;
        if (std.mem.indexOf(u8, line, "\"accepted\":true") != null) {
            out.successes += 1;
        } else {
            out.failures += 1;
        }
    }
    return out;
}

fn candidateWorktreePath(allocator: std.mem.Allocator, io: std.Io, worktree_root: []const u8, agent: []const u8) ![]u8 {
    const name = try std.fmt.allocPrint(allocator, "cli-candidate-{s}", .{agent});
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ worktree_root, name });
    errdefer allocator.free(path);
    if (path.len != 0 and path[0] == '/') return path;
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    defer allocator.free(path);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn invocationForSpec(allocator: std.mem.Allocator, spec: probe.DetectSpec, task_text_value: []const u8, worktree_path: []const u8) !adapter.OwnedInvocation {
    if (spec.task_argv) |argv| {
        return adapter.ownInvocation(allocator, .{
            .executable = argv[0],
            .argv = argv,
            .cwd = ".",
        });
    }

    const task = types.Task{
        .id = "cli-task",
        .role = .worker,
        .intent = .implement,
        .instruction = task_text_value,
        .worktree_path = worktree_path,
        .context = "",
        .target_files = &.{},
        .timeout_ms = 180000,
        .read_only = false,
    };
    if (std.mem.eql(u8, spec.profile.name, "claude-code")) return claude_code.buildInvocation(allocator, .supported_1, task);
    if (std.mem.eql(u8, spec.profile.name, "codex")) return codex.buildInvocation(allocator, .supported_1, task);
    if (std.mem.eql(u8, spec.profile.name, "antigravity")) return antigravity.buildInvocation(allocator, .degraded_text, task);
    return error.UnsupportedProfile;
}

fn defaultVerifyCommands() []const verify.Command {
    return &.{
        .{ .name = "build", .argv = &.{ "zig", "build" } },
        .{ .name = "test", .argv = &.{ "zig", "build", "test" } },
    };
}

// ---------------------------------------------------------------------------
// Async job CLI: submit / poll / wait / jobs
// ---------------------------------------------------------------------------

fn submitJob(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    repo_path: []const u8,
) !Result {
    const task = subcommandTask(args[2..]) orelse {
        return .{
            .code = exit_usage,
            .text = try allocator.dupe(u8, "usage: openfugu submit \"task\"\n"),
        };
    };
    // Generate a short unique id: timestamp + random suffix.
    const id = try generateJobId(allocator, io);
    defer allocator.free(id);

    // Write the queued job file before spawning so poll sees it even
    // if the child has not started yet.
    try jobs.write(allocator, io, .{
        .id = id,
        .status = .queued,
        .task = task,
        .created_ms = nowMs(io),
    });

    // Build the child argv: openfugu run --job-id=<id> [flags] "task"
    var child_argv = std.array_list.Managed([]const u8).init(allocator);
    defer child_argv.deinit();
    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    try child_argv.append(self_path);
    const job_id_flag = try std.fmt.allocPrint(allocator, "--job-id={s}", .{id});
    defer allocator.free(job_id_flag);
    try child_argv.append("run");
    try child_argv.append(job_id_flag);
    // Forward select flags so submit respects --planner / --agents / --mode.
    const planners = optionValue(args, "--planner");
    if (planners) |p| {
        const inline_flag = try std.fmt.allocPrint(allocator, "--planner={s}", .{p});
        defer allocator.free(inline_flag);
        try child_argv.append(inline_flag);
    }
    const agents = optionValue(args, "--agents");
    if (agents) |a| {
        const inline_flag = try std.fmt.allocPrint(allocator, "--agents={s}", .{a});
        defer allocator.free(inline_flag);
        try child_argv.append(inline_flag);
    }
    const mode = optionValue(args, "--mode");
    if (mode) |m| {
        const inline_flag = try std.fmt.allocPrint(allocator, "--mode={s}", .{m});
        defer allocator.free(inline_flag);
        try child_argv.append(inline_flag);
    }
    if (hasFlag(args, "--no-apply")) try child_argv.append("--no-apply");
    try child_argv.append(task);

    // Spawn detached. We do not wait. The child updates the job file
    // itself. Setting child.id to null after spawn prevents the Child
    // deinit from killing the process when it goes out of scope.
    _ = repo_path; // child resolves its own cwd from the inherited cwd.
    var child = std.process.spawn(io, .{
        .argv = child_argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        // Mark the job failed so poll/wait do not hang.
        try jobs.write(allocator, io, .{
            .id = id,
            .status = .failed,
            .task = task,
            .created_ms = nowMs(io),
            .ended_ms = nowMs(io),
            .summary = @errorName(err),
        });
        const text = try std.fmt.allocPrint(allocator, "submit failed: {s}\njob_id={s}\n", .{ @errorName(err), id });
        return .{ .code = exit_planner, .text = text };
    };
    // Detach: clear the id so deinit does not kill the child.
    child.id = null;

    return .{
        .code = exit_ok,
        .text = try std.fmt.allocPrint(allocator, "job_id={s}\nstatus=queued\npoll with: openfugu poll {s}\n", .{ id, id }),
    };
}

fn pollJob(allocator: std.mem.Allocator, io: std.Io, id: []const u8) !Result {
    var job = (try jobs.read(allocator, io, id)) orelse {
        return .{
            .code = exit_no_agent,
            .text = try std.fmt.allocPrint(allocator, "job {s} not found\n", .{id}),
        };
    };
    defer jobs.deinitJob(allocator, &job);
    const text = try renderJob(allocator, job);
    return .{
        .code = if (job.status == .ok) exit_ok else if (job.status == .failed or job.status == .canceled) exit_verify else exit_ok,
        .text = text,
    };
}

fn waitJob(allocator: std.mem.Allocator, io: std.Io, id: []const u8) !Result {
    // Poll loop: read the job file, sleep, repeat. We do not maintain a
    // daemon, so this is a stateless file poll. The child is responsible
    // for updating the file at completion.
    const deadline_ms = nowMs(io) + 30 * 60 * 1000; // 30 minute cap.
    while (true) {
        var job = (try jobs.read(allocator, io, id)) orelse {
            return .{
                .code = exit_no_agent,
                .text = try std.fmt.allocPrint(allocator, "job {s} not found\n", .{id}),
            };
        };
        const done = job.status == .ok or job.status == .failed or job.status == .canceled;
        if (done) {
            const text = try renderJob(allocator, job);
            const code = if (job.status == .ok) exit_ok else if (job.exit_code) |c| c else exit_verify;
            jobs.deinitJob(allocator, &job);
            return .{ .code = code, .text = text };
        }
        jobs.deinitJob(allocator, &job);
        if (nowMs(io) >= deadline_ms) {
            return .{
                .code = exit_budget,
                .text = try std.fmt.allocPrint(allocator, "job {s} timed out waiting for completion\n", .{id}),
            };
        }
        // Sleep 500ms between polls. This is a background wait, not a
        // tight loop, so the cost is negligible.
        io.sleep(std.Io.Duration.fromMilliseconds(500), .awake) catch {};
    }
}

fn listJobs(allocator: std.mem.Allocator, io: std.Io) !Result {
    const ids = try jobs.listIds(allocator, io);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (ids.len == 0) {
        try out.appendSlice(allocator, "no jobs\n");
        return .{ .code = exit_ok, .text = try out.toOwnedSlice(allocator) };
    }
    for (ids) |id| {
        var job = (try jobs.read(allocator, io, id)) orelse {
            try out.print(allocator, "{s} status=missing\n", .{id});
            continue;
        };
        defer jobs.deinitJob(allocator, &job);
        try out.print(allocator, "{s} status={s} agent={s} exit={?}\n", .{
            job.id,
            @tagName(job.status),
            if (job.agent.len == 0) "unknown" else job.agent,
            job.exit_code,
        });
    }
    return .{ .code = exit_ok, .text = try out.toOwnedSlice(allocator) };
}

fn renderJob(allocator: std.mem.Allocator, job: jobs.Job) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\id={s}
        \\status={s}
        \\task={s}
        \\agent={s}
        \\router={s}
        \\route={s}
        \\exit_code={?}
        \\created_ms={d}
        \\started_ms={d}
        \\ended_ms={d}
        \\summary={s}
        \\
    , .{
        job.id,
        @tagName(job.status),
        job.task,
        if (job.agent.len == 0) "unknown" else job.agent,
        if (job.router.len == 0) "unknown" else job.router,
        if (job.route.len == 0) "unknown" else job.route,
        job.exit_code,
        job.created_ms,
        job.started_ms,
        job.ended_ms,
        job.summary,
    });
}

fn generateJobId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    // job_<ms>_<pid4hex>: timestamp ensures ordering, pid adds uniqueness
    // within a single millisecond. Good enough for a local jobs dir.
    const ms = nowMs(io);
    const pid: u32 = @intCast(std.os.linux.getpid());
    return std.fmt.allocPrint(allocator, "job_{d}_{x:0>8}", .{ ms, pid });
}

fn nowMs(io: std.Io) u64 {
    // Best-effort wall-clock timestamp in milliseconds. Falls back to 0
    // if the clock is unavailable; jobs still work because status is the
    // field pollers check, not the timestamp.
    const ts = std.Io.Timestamp.now(io, .real);
    const ms = ts.toMilliseconds();
    return @intCast(@max(ms, 0));
}
