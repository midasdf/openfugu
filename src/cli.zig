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
const verify = @import("verify/commands.zig");
const types = @import("core/types.zig");
const adapter = @import("adapter/adapter.zig");

const claude_version_argv = [_][]const u8{ "claude", "--version" };
const claude_auth_argv = [_][]const u8{ "claude", "auth", "status" };
const codex_version_argv = [_][]const u8{ "codex", "--version" };
const codex_auth_argv = [_][]const u8{ "codex", "login", "status" };
const agy_version_argv = [_][]const u8{ "agy", "--version" };
const agy_auth_argv = [_][]const u8{ "agy", "auth", "status" };

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
        return runFirstRunnableSpec(allocator, io, specs, repo_path, worktree_root, verify_commands, task, hasFlag(args, "--no-apply"), optionValue(args, "--agents"), optionValue(args, "--mode"));
    }
    return run(allocator, args);
}

pub fn runAlloc(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    if (args.len <= 1) return std.fmt.allocPrint(allocator, "openfugu {s}\n", .{config.version});

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "plan")) {
        if (args.len < 3) return error.InvalidArgs;
        var plan = try heuristic.plan(allocator, .{ .request = args[2] });
        defer planner.deinitPlan(allocator, &plan);
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
    if (std.mem.eql(u8, cmd, "agents")) {
        return renderAgents(allocator, defaultAgentReports());
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

fn taskText(args: []const []const u8) !?[]const u8 {
    if (args.len <= 1) return null;
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "plan")) return null;
    if (std.mem.eql(u8, cmd, "doctor")) return null;
    if (std.mem.eql(u8, cmd, "agents")) return null;
    if (std.mem.eql(u8, cmd, "usage")) return null;
    if (std.mem.eql(u8, cmd, "replay")) return null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--subscription-only") or std.mem.eql(u8, arg, "--no-apply")) continue;
        if (takesValue(arg)) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArgs;
        return arg;
    }
    return error.InvalidArgs;
}

fn takesValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--mode") or
        std.mem.eql(u8, arg, "--agents") or
        std.mem.eql(u8, arg, "--planner") or
        std.mem.eql(u8, arg, "--depth");
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
) !Result {
    try std.Io.Dir.cwd().createDirPath(io, worktree_root);
    var saw_runnable = false;
    for (specs) |spec| {
        if (!agentAllowed(agents_filter, spec.name)) continue;
        var report_value = try probe.detect(allocator, io, spec);
        defer report_value.deinit(allocator);
        if (!report_value.runnable) continue;
        saw_runnable = true;

        var owned_invocation = try invocationForSpec(allocator, spec, task_text);
        defer owned_invocation.deinit(allocator);
        var summary = try conductor.runInvocationSingle(allocator, .{
            .repo_path = repo_path,
            .worktree_root = worktree_root,
            .run_id = "cli",
            .candidate_id = "candidate",
            .agent_id = report_value.name,
            .invocation = owned_invocation.value,
            .timeout_ms = 180000,
            .io = io,
            .verify_commands = verify_commands,
            .apply = !no_apply,
        });
        defer summary.deinit(allocator);

        const code = if (summary.accepted and (no_apply or (summary.applied and summary.reverified))) exit_ok else exit_verify;
        if (code != exit_ok and continuesAfterFailure(mode)) continue;
        return .{
            .code = code,
            .text = try std.fmt.allocPrint(allocator, "agent={s} accepted={} applied={} reverified={}\n", .{
                report_value.name,
                summary.accepted,
                summary.applied,
                summary.reverified,
            }),
        };
    }
    if (saw_runnable) {
        return .{
            .code = exit_verify,
            .text = try allocator.dupe(u8, "no candidate passed verification\n"),
        };
    }
    return .{
        .code = exit_no_agent,
        .text = try allocator.dupe(u8, "no subscription-compatible agent available; run `openfugu doctor` for details\n"),
    };
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn optionValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

fn agentAllowed(filter: ?[]const u8, name: []const u8) bool {
    const text = filter orelse return true;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}

fn continuesAfterFailure(mode: ?[]const u8) bool {
    const value = mode orelse return false;
    return std.mem.eql(u8, value, "race") or std.mem.eql(u8, value, "ensemble");
}

fn invocationForSpec(allocator: std.mem.Allocator, spec: probe.DetectSpec, task_text_value: []const u8) !adapter.OwnedInvocation {
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
        .worktree_path = ".",
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
