const std = @import("std");
const types = @import("../core/types.zig");
const policy = @import("../conductor/policy.zig");
const heuristic = @import("heuristic.zig");
const planner = @import("planner.zig");

/// capability is a deterministic planner that inspects the classified
/// task kind and emits a plan whose node selectors are capability
/// queries rather than bare "any_healthy". This lets the scheduler pick
/// agents based on what the task structurally needs (file edits, command
/// execution, read-only analysis) instead of only on keyword preference.
///
/// The topology mirrors heuristic.plan but the node selectors carry
/// capability requirements so agents that lack the right capabilities
/// are skipped at scheduling time rather than failing at run time.
pub fn plan(allocator: std.mem.Allocator, req: heuristic.PlanRequest) !types.WorkflowPlan {
    const classified = policy.classifyTaskConfidence(req.request);
    return planClassified(allocator, .{
        .request = req.request,
        .kind = classified.kind,
    });
}

pub const ClassifiedRequest = struct {
    request: []const u8,
    kind: policy.TaskKind,
};

pub fn planClassified(allocator: std.mem.Allocator, req: ClassifiedRequest) !types.WorkflowPlan {
    // Frontend and broad tasks benefit from a thinker-first chain so the
    // worker gets a concrete change surface instead of a vague instruction.
    if (req.kind == .frontend or req.kind == .broad or req.kind == .review) {
        return chainWithCapability(allocator, req.request, req.kind);
    }
    return oneShotWithCapability(allocator, req.request, req.kind);
}

fn oneShotWithCapability(allocator: std.mem.Allocator, request: []const u8, kind: policy.TaskKind) !types.WorkflowPlan {
    var nodes = try allocator.alloc(types.PlanNode, 1);
    errdefer allocator.free(nodes);
    nodes[0] = .{
        .id = 1,
        .role = .worker,
        .intent = .implement,
        .selector = selectorFor(kind, .worker),
        .instruction = request,
        .depends_on = try emptyIds(allocator),
        .access = try refs(allocator, &.{.original_request}),
        .creates_candidate = true,
    };
    errdefer freeNodeSlices(allocator, nodes);
    return finish(allocator, .one_shot, nodes, "capability-aware single change");
}

fn chainWithCapability(allocator: std.mem.Allocator, request: []const u8, kind: policy.TaskKind) !types.WorkflowPlan {
    var nodes = try allocator.alloc(types.PlanNode, 2);
    errdefer allocator.free(nodes);
    nodes[0] = .{
        .id = 1,
        .role = .thinker,
        .intent = .analyze,
        .selector = selectorFor(kind, .thinker),
        .instruction = "Analyze the request and identify the change surface.",
        .depends_on = try emptyIds(allocator),
        .access = try refs(allocator, &.{.original_request}),
        .creates_candidate = false,
    };
    nodes[1] = .{
        .id = 2,
        .role = .worker,
        .intent = .implement,
        .selector = selectorFor(kind, .worker),
        .instruction = request,
        .depends_on = try ids(allocator, &.{1}),
        .access = try refs(allocator, &.{ .original_request, .{ .node_output = 1 } }),
        .creates_candidate = true,
    };
    errdefer freeNodeSlices(allocator, nodes);
    return finish(allocator, .chain, nodes, "capability-aware think before change");
}

/// selectorFor maps a task kind plus role to a capability query. The
/// scheduler resolves the query against agent profiles, so an agent
/// that lacks edit_files will never be picked for a worker node.
fn selectorFor(kind: policy.TaskKind, role: types.Role) types.AgentSelector {
    _ = role;
    return switch (kind) {
        .terminal, .test_fix => .{ .capability = .{ .run_commands = true, .edit_files = true } },
        .bugfix, .refactor, .frontend => .{ .capability = .{ .edit_files = true } },
        .review => .{ .capability = .{ .structured_output = true } },
        .broad, .general => .any_healthy,
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

// Silence unused-import warning: planner is imported for deinitPlan
// symmetry but capability plans are freed by the same helper.
comptime {
    _ = planner;
}
