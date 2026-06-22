const std = @import("std");
const types = @import("../core/types.zig");

pub const PlanRequest = struct {
    request: []const u8,
};

pub fn plan(allocator: std.mem.Allocator, req: PlanRequest) !types.WorkflowPlan {
    if (contains(req.request, "compare") or contains(req.request, "independent")) {
        return fanOut(allocator, req.request);
    }
    if (contains(req.request, "investigate") or contains(req.request, "broad") or contains(req.request, "unclear")) {
        return chain(allocator, req.request);
    }
    return oneShot(allocator, req.request);
}

pub fn repair(allocator: std.mem.Allocator, candidate_id: types.CandidateId) !types.WorkflowPlan {
    var nodes = try allocator.alloc(types.PlanNode, 1);
    errdefer allocator.free(nodes);
    nodes[0] = .{
        .id = 1,
        .role = .worker,
        .intent = .repair,
        .selector = .any_healthy,
        .instruction = "Repair the rejected candidate using the verification result.",
        .depends_on = try emptyIds(allocator),
        .access = try refs(allocator, &.{ .{ .verification = candidate_id }, .original_request }),
        .creates_candidate = true,
    };
    errdefer freeNodeSlices(allocator, nodes);

    return finish(allocator, .refinement, nodes, "repair after verifier failure");
}

fn oneShot(allocator: std.mem.Allocator, request: []const u8) !types.WorkflowPlan {
    var nodes = try allocator.alloc(types.PlanNode, 1);
    errdefer allocator.free(nodes);
    nodes[0] = .{
        .id = 1,
        .role = .worker,
        .intent = .implement,
        .selector = .any_healthy,
        .instruction = request,
        .depends_on = try emptyIds(allocator),
        .access = try refs(allocator, &.{.original_request}),
        .creates_candidate = true,
    };
    errdefer freeNodeSlices(allocator, nodes);

    return finish(allocator, .one_shot, nodes, "single local change");
}

fn chain(allocator: std.mem.Allocator, request: []const u8) !types.WorkflowPlan {
    var nodes = try allocator.alloc(types.PlanNode, 2);
    errdefer allocator.free(nodes);
    nodes[0] = .{
        .id = 1,
        .role = .thinker,
        .intent = .analyze,
        .selector = .any_healthy,
        .instruction = "Analyze the request and identify the change surface.",
        .depends_on = try emptyIds(allocator),
        .access = try refs(allocator, &.{.original_request}),
        .creates_candidate = false,
    };
    nodes[1] = .{
        .id = 2,
        .role = .worker,
        .intent = .implement,
        .selector = .any_healthy,
        .instruction = request,
        .depends_on = try ids(allocator, &.{1}),
        .access = try refs(allocator, &.{ .original_request, .{ .node_output = 1 } }),
        .creates_candidate = true,
    };
    errdefer freeNodeSlices(allocator, nodes);

    return finish(allocator, .chain, nodes, "think before broad change");
}

fn fanOut(allocator: std.mem.Allocator, request: []const u8) !types.WorkflowPlan {
    var nodes = try allocator.alloc(types.PlanNode, 3);
    errdefer allocator.free(nodes);
    nodes[0] = worker(try refs(allocator, &.{.original_request}), request, 1, 1);
    nodes[1] = worker(try refs(allocator, &.{.original_request}), request, 2, 1);
    nodes[2] = .{
        .id = 3,
        .role = .verifier,
        .intent = .synthesize,
        .selector = .any_healthy,
        .instruction = "Compare verified candidates and select the safer result.",
        .depends_on = try ids(allocator, &.{ 1, 2 }),
        .access = try refs(allocator, &.{ .original_request, .{ .node_output = 1 }, .{ .node_output = 2 } }),
        .creates_candidate = false,
    };
    nodes[0].depends_on = try emptyIds(allocator);
    nodes[1].depends_on = try emptyIds(allocator);
    errdefer freeNodeSlices(allocator, nodes);

    return finish(allocator, .fan_out_fan_in, nodes, "compare independent candidates");
}

fn worker(access: []types.ContextRef, instruction: []const u8, id_value: types.NodeId, group: u32) types.PlanNode {
    return .{
        .id = id_value,
        .role = .worker,
        .intent = .implement,
        .selector = .any_healthy,
        .instruction = instruction,
        .depends_on = &.{},
        .access = access,
        .creates_candidate = true,
        .parallel_group = group,
    };
}

fn finish(
    allocator: std.mem.Allocator,
    topology: types.Topology,
    nodes: []types.PlanNode,
    rationale: []const u8,
) !types.WorkflowPlan {
    const final_nodes = try allocator.alloc(types.NodeId, 1);
    final_nodes[0] = nodes[nodes.len - 1].id;
    return .{
        .topology = topology,
        .nodes = nodes,
        .final_nodes = final_nodes,
        .rationale = rationale,
    };
}

fn emptyIds(allocator: std.mem.Allocator) ![]types.NodeId {
    return allocator.alloc(types.NodeId, 0);
}

fn ids(allocator: std.mem.Allocator, values: []const types.NodeId) ![]types.NodeId {
    return allocator.dupe(types.NodeId, values);
}

fn refs(allocator: std.mem.Allocator, values: []const types.ContextRef) ![]types.ContextRef {
    return allocator.dupe(types.ContextRef, values);
}

fn freeNodeSlices(allocator: std.mem.Allocator, nodes: []types.PlanNode) void {
    for (nodes) |node| {
        allocator.free(node.depends_on);
        allocator.free(node.access);
    }
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}
