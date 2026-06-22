const std = @import("std");
const probe = @import("../adapter/probe.zig");

pub const Input = struct {
    config_ok: bool,
    git_ok: bool,
    worktree_ok: bool,
    subscription_only: bool,
    agents: []const probe.AgentReport,
};

pub fn render(allocator: std.mem.Allocator, input: Input) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "config={s} git={s} worktree={s} subscription-only={s} secrets=hidden\n", .{
        status(input.config_ok),
        status(input.git_ok),
        status(input.worktree_ok),
        status(input.subscription_only),
    });
    for (input.agents) |agent| {
        try out.print(allocator, "{s} exists={} version={s} compatibility={s} auth={s} non_interactive={} structured_output={} runnable={} overage={s}\n", .{
            agent.name,
            agent.exists,
            if (agent.version.len == 0) "unknown" else agent.version,
            @tagName(agent.compatibility),
            @tagName(agent.auth),
            agent.non_interactive,
            agent.structured_output,
            agent.runnable,
            if (agent.overage_known) "known" else "unknown",
        });
    }
    return out.toOwnedSlice(allocator);
}

fn status(ok: bool) []const u8 {
    return if (ok) "ok" else "fail";
}
