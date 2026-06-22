const std = @import("std");
const heuristic = @import("heuristic.zig");
const planner = @import("planner.zig");
const types = @import("../core/types.zig");

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
        // ponytail: real schema parsing lands with full CLI planner; invalid/unknown text falls back now.
        return heuristic.plan(allocator, .{ .request = req.original_request });
    }
    return heuristic.plan(allocator, .{ .request = req.original_request });
}

fn looksLikeWorkflowJson(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \n\r\t");
    return trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}';
}
