const std = @import("std");
const heuristic = @import("heuristic.zig");
const planner = @import("planner.zig");
const types = @import("../core/types.zig");
const validate = @import("validate.zig");

pub const Request = struct {
    original_request: []const u8,
    safe_repo_summary: []const u8,
};

pub const Result = union(enum) {
    unavailable,
    delegated: planner.PlannerBackend,
};

pub fn planOrFallback(allocator: std.mem.Allocator, req: Request, raw_output: []const u8) !types.WorkflowPlan {
    if (looksLikeWorkflowJson(raw_output)) {
        if (std.mem.indexOf(u8, raw_output, "\"id\":2") != null) {
            if (parseTwoNodeChain(allocator, raw_output)) |plan| return plan else |_| {}
        }
        if (parseMinimalPlan(allocator, raw_output)) |plan| return plan else |_| {}
        return heuristic.plan(allocator, .{ .request = req.original_request });
    }
    return heuristic.plan(allocator, .{ .request = req.original_request });
}

fn looksLikeWorkflowJson(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \n\r\t");
    return trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}';
}

fn parseMinimalPlan(allocator: std.mem.Allocator, raw: []const u8) !types.WorkflowPlan {
    const instruction = try jsonStringTemp(raw, "\"instruction\"");
    const rationale = try jsonStringTemp(raw, "\"rationale\"");
    const id = try jsonU64(raw, "\"id\"");
    const final_id = try firstArrayU64(raw, "\"final_nodes\"");
    const role = try roleFromString(try jsonStringTemp(raw, "\"role\""));
    const intent = try intentFromString(try jsonStringTemp(raw, "\"intent\""));
    const topology = try topologyFromString(try jsonStringTemp(raw, "\"topology\""));
    const creates_candidate = jsonBool(raw, "\"creates_candidate\"") orelse false;

    var nodes = try allocator.alloc(types.PlanNode, 1);
    errdefer allocator.free(nodes);
    nodes[0] = .{
        .id = id,
        .role = role,
        .intent = intent,
        .selector = .any_healthy,
        .instruction = instruction,
        .depends_on = try allocator.alloc(types.NodeId, 0),
        .access = try allocator.dupe(types.ContextRef, &.{.original_request}),
        .creates_candidate = creates_candidate,
    };
    errdefer {
        allocator.free(nodes[0].depends_on);
        allocator.free(nodes[0].access);
    }

    const final_nodes = try allocator.alloc(types.NodeId, 1);
    errdefer allocator.free(final_nodes);
    final_nodes[0] = final_id;

    var plan = types.WorkflowPlan{
        .topology = topology,
        .nodes = nodes,
        .final_nodes = final_nodes,
        .rationale = rationale,
    };
    errdefer planner.deinitPlan(allocator, &plan);
    try validate.validatePlan(plan);
    return plan;
}

fn parseTwoNodeChain(allocator: std.mem.Allocator, raw: []const u8) !types.WorkflowPlan {
    const first = try objectContaining(raw, "\"id\":1");
    const second = try objectContaining(raw, "\"id\":2");
    const final_id = try firstArrayU64(raw, "\"final_nodes\"");
    const rationale = try jsonStringTemp(raw, "\"rationale\"");

    var nodes = try allocator.alloc(types.PlanNode, 2);
    errdefer allocator.free(nodes);
    nodes[0] = .{
        .id = 1,
        .role = try roleFromString(try jsonStringTemp(first, "\"role\"")),
        .intent = try intentFromString(try jsonStringTemp(first, "\"intent\"")),
        .selector = .any_healthy,
        .instruction = try jsonStringTemp(first, "\"instruction\""),
        .depends_on = try allocator.alloc(types.NodeId, 0),
        .access = try allocator.dupe(types.ContextRef, &.{.original_request}),
        .creates_candidate = jsonBool(first, "\"creates_candidate\"") orelse false,
    };
    errdefer {
        allocator.free(nodes[0].depends_on);
        allocator.free(nodes[0].access);
    }
    nodes[1] = .{
        .id = 2,
        .role = try roleFromString(try jsonStringTemp(second, "\"role\"")),
        .intent = try intentFromString(try jsonStringTemp(second, "\"intent\"")),
        .selector = .any_healthy,
        .instruction = try jsonStringTemp(second, "\"instruction\""),
        .depends_on = try allocator.dupe(types.NodeId, &.{1}),
        .access = try allocator.dupe(types.ContextRef, &.{.{ .node_output = 1 }}),
        .creates_candidate = jsonBool(second, "\"creates_candidate\"") orelse false,
    };
    errdefer {
        allocator.free(nodes[1].depends_on);
        allocator.free(nodes[1].access);
    }

    const final_nodes = try allocator.alloc(types.NodeId, 1);
    final_nodes[0] = final_id;
    errdefer allocator.free(final_nodes);

    const plan = types.WorkflowPlan{
        .topology = try topologyFromString(try jsonStringTemp(raw, "\"topology\"")),
        .nodes = nodes,
        .final_nodes = final_nodes,
        .rationale = rationale,
    };
    try validate.validatePlan(plan);
    return plan;
}

fn objectContaining(raw: []const u8, needle: []const u8) ![]const u8 {
    const needle_pos = std.mem.indexOf(u8, raw, needle) orelse return error.MissingField;
    const start = std.mem.lastIndexOfScalar(u8, raw[0..needle_pos], '{') orelse return error.InvalidJson;
    const end_rel = std.mem.indexOfScalarPos(u8, raw, needle_pos, '}') orelse return error.InvalidJson;
    return raw[start .. end_rel + 1];
}

fn jsonStringTemp(raw: []const u8, key: []const u8) ![]const u8 {
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return error.MissingField;
    const colon = std.mem.indexOfScalarPos(u8, raw, key_pos + key.len, ':') orelse return error.InvalidJson;
    const first_quote = std.mem.indexOfScalarPos(u8, raw, colon + 1, '"') orelse return error.InvalidJson;
    const second_quote = std.mem.indexOfScalarPos(u8, raw, first_quote + 1, '"') orelse return error.InvalidJson;
    return raw[first_quote + 1 .. second_quote];
}

fn jsonU64(raw: []const u8, key: []const u8) !u64 {
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return error.MissingField;
    const colon = std.mem.indexOfScalarPos(u8, raw, key_pos + key.len, ':') orelse return error.InvalidJson;
    var start = colon + 1;
    while (start < raw.len and raw[start] == ' ') start += 1;
    var end = start;
    while (end < raw.len and raw[end] >= '0' and raw[end] <= '9') end += 1;
    if (end == start) return error.InvalidJson;
    return std.fmt.parseInt(u64, raw[start..end], 10);
}

fn firstArrayU64(raw: []const u8, key: []const u8) !u64 {
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return error.MissingField;
    const open = std.mem.indexOfScalarPos(u8, raw, key_pos + key.len, '[') orelse return error.InvalidJson;
    var start = open + 1;
    while (start < raw.len and raw[start] == ' ') start += 1;
    var end = start;
    while (end < raw.len and raw[end] >= '0' and raw[end] <= '9') end += 1;
    if (end == start) return error.InvalidJson;
    return std.fmt.parseInt(u64, raw[start..end], 10);
}

fn jsonBool(raw: []const u8, key: []const u8) ?bool {
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, raw, key_pos + key.len, ':') orelse return null;
    const rest = std.mem.trim(u8, raw[colon + 1 ..], " ");
    if (std.mem.startsWith(u8, rest, "true")) return true;
    if (std.mem.startsWith(u8, rest, "false")) return false;
    return null;
}

fn roleFromString(value: []const u8) !types.Role {
    if (std.mem.eql(u8, value, "thinker")) return .thinker;
    if (std.mem.eql(u8, value, "worker")) return .worker;
    if (std.mem.eql(u8, value, "verifier")) return .verifier;
    return error.InvalidRole;
}

fn intentFromString(value: []const u8) !types.Intent {
    if (std.mem.eql(u8, value, "analyze")) return .analyze;
    if (std.mem.eql(u8, value, "plan")) return .plan;
    if (std.mem.eql(u8, value, "implement")) return .implement;
    if (std.mem.eql(u8, value, "review")) return .review;
    if (std.mem.eql(u8, value, "synthesize")) return .synthesize;
    if (std.mem.eql(u8, value, "repair")) return .repair;
    if (std.mem.eql(u8, value, "resolve_conflict")) return .resolve_conflict;
    return error.InvalidIntent;
}

fn topologyFromString(value: []const u8) !types.Topology {
    if (std.mem.eql(u8, value, "one_shot")) return .one_shot;
    if (std.mem.eql(u8, value, "chain")) return .chain;
    if (std.mem.eql(u8, value, "fan_out_fan_in")) return .fan_out_fan_in;
    if (std.mem.eql(u8, value, "race")) return .race;
    if (std.mem.eql(u8, value, "refinement")) return .refinement;
    return error.InvalidTopology;
}
