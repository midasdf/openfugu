const std = @import("std");
const types = @import("../core/types.zig");

pub fn readyNodes(
    allocator: std.mem.Allocator,
    nodes: []const types.PlanNode,
    completed: []const types.NodeId,
) ![]types.NodeId {
    var ready: std.ArrayList(types.NodeId) = .empty;
    errdefer ready.deinit(allocator);

    for (nodes) |node| {
        if (contains(completed, node.id)) continue;
        var ready_now = true;
        for (node.depends_on) |dep| {
            if (!contains(completed, dep)) {
                ready_now = false;
                break;
            }
        }
        if (ready_now) try ready.append(allocator, node.id);
    }

    return ready.toOwnedSlice(allocator);
}

fn contains(ids: []const types.NodeId, id: types.NodeId) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}
