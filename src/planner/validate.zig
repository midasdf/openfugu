const types = @import("../core/types.zig");

pub fn validatePlan(plan: types.WorkflowPlan) !void {
    if (plan.nodes.len == 0) return error.EmptyPlan;

    for (plan.nodes, 0..) |node, i| {
        if (findNode(plan.nodes[0..i], node.id) != null) return error.DuplicateNode;

        for (node.depends_on) |dep| {
            const dep_index = findIndex(plan.nodes, dep) orelse return error.UnknownDependency;
            if (dep_index >= i) return error.CyclicDependency;
        }

        for (node.access) |access| switch (access) {
            .node_output => |id| {
                const dep_index = findIndex(plan.nodes, id) orelse return error.UnknownAccessRef;
                if (dep_index >= i) return error.FutureAccessRef;
            },
            .selected_prior => |ids| for (ids) |id| {
                const dep_index = findIndex(plan.nodes, id) orelse return error.UnknownAccessRef;
                if (dep_index >= i) return error.FutureAccessRef;
            },
            else => {},
        };
    }

    for (plan.final_nodes) |id| {
        _ = findIndex(plan.nodes, id) orelse return error.UnknownFinalNode;
    }
}

fn findNode(nodes: []const types.PlanNode, id: types.NodeId) ?types.PlanNode {
    // ponytail: O(n^2) scans are fine for small plans; use a map if plan size grows.
    for (nodes) |node| if (node.id == id) return node;
    return null;
}

fn findIndex(nodes: []const types.PlanNode, id: types.NodeId) ?usize {
    for (nodes, 0..) |node, i| if (node.id == id) return i;
    return null;
}
