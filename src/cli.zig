const std = @import("std");
const config = @import("config.zig");
const heuristic = @import("planner/heuristic.zig");
const planner = @import("planner/planner.zig");
const doctor = @import("obs/doctor.zig");
const probe = @import("adapter/probe.zig");
const usage = @import("obs/usage.zig");
const replay = @import("obs/replay.zig");

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
    if (isTaskCommand(args)) {
        return .{
            .code = exit_no_agent,
            .text = try allocator.dupe(u8, "no subscription-compatible agent available; run `openfugu doctor` for details\n"),
        };
    }
    return .{ .code = exit_ok, .text = try runAlloc(allocator, args) };
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

    if (std.mem.startsWith(u8, cmd, "--")) {
        return allocator.dupe(u8, "no subscription-compatible agent available; run `openfugu doctor` for details\n");
    }
    return allocator.dupe(u8, "no subscription-compatible agent available; run `openfugu doctor` for details\n");
}

fn isTaskCommand(args: []const []const u8) bool {
    if (args.len <= 1) return false;
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "plan")) return false;
    if (std.mem.eql(u8, cmd, "doctor")) return false;
    if (std.mem.eql(u8, cmd, "agents")) return false;
    if (std.mem.eql(u8, cmd, "usage")) return false;
    if (std.mem.eql(u8, cmd, "replay")) return false;
    return true;
}

fn defaultAgentReports() []const probe.AgentReport {
    return &.{
        .{ .name = "claude", .compatibility = .unknown, .auth = .unknown, .runnable = false },
        .{ .name = "codex", .compatibility = .unknown, .auth = .unknown, .runnable = false },
        .{ .name = "agy", .compatibility = .unknown, .auth = .unknown, .runnable = false },
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
