const std = @import("std");
const types = @import("../core/types.zig");

pub const PlannerBackend = enum {
    heuristic,
    subscription_agent,
    capability,
};

pub fn deinitPlan(allocator: std.mem.Allocator, plan: *types.WorkflowPlan) void {
    for (plan.nodes) |node| {
        allocator.free(node.depends_on);
        allocator.free(node.access);
    }
    allocator.free(plan.nodes);
    allocator.free(plan.final_nodes);
    plan.* = undefined;
}
