const planner = @import("planner.zig");

pub const Request = struct {
    original_request: []const u8,
    safe_repo_summary: []const u8,
};

pub const Result = union(enum) {
    unavailable,
    delegated: planner.PlannerBackend,
};
