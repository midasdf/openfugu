const types = @import("../core/types.zig");

pub const AgentStats = struct {
    id: []const u8,
    vendor: []const u8,
    auth: types.AuthKind,
    compatibility: types.Compatibility,
    busy: bool = false,
    cooldown_until_ms: u64 = 0,
    recent_rate_limits: u32 = 0,
    calls: u64 = 0,
    successes: u64 = 0,
    failures: u64 = 0,
};

pub fn chooseAgent(agents: []const AgentStats, now_ms: u64) !AgentStats {
    for (agents) |agent| {
        if (agent.busy) continue;
        if (agent.cooldown_until_ms > now_ms) continue;
        if (agent.compatibility != .supported and agent.compatibility != .degraded) continue;
        if (agent.auth != .subscription and agent.auth != .organization_subscription) continue;
        return agent;
    }
    return error.NoAvailableAgent;
}

pub fn recordRateLimit(agent: *AgentStats, now_ms: u64) void {
    agent.recent_rate_limits += 1;
    agent.cooldown_until_ms = now_ms + backoffMs(agent.recent_rate_limits);
}

fn backoffMs(rate_limits: u32) u64 {
    const shift: u6 = @intCast(@min(rate_limits, 6));
    return @as(u64, 1000) << shift;
}
