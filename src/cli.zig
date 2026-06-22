const std = @import("std");
const config = @import("config.zig");
const heuristic = @import("planner/heuristic.zig");
const planner = @import("planner/planner.zig");
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
        return allocator.dupe(u8, "config=ok git=unchecked subscription-only=enabled claude=unknown codex=unknown agy=unknown worktree=unchecked secrets=hidden\n");
    }
    if (std.mem.eql(u8, cmd, "agents")) {
        return allocator.dupe(u8, "claude compatibility=unknown auth=unknown runnable=false\ncodex compatibility=unknown auth=unknown runnable=false\nagy compatibility=unknown auth=unknown runnable=false\n");
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
        return allocator.dupe(u8, "mode=auto accepted=false reason=not-run no-apply=false\n");
    }
    return allocator.dupe(u8, "mode=auto accepted=false reason=not-run\n");
}
