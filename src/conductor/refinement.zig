const std = @import("std");
const budget_mod = @import("../core/budget.zig");

pub const FakeCandidate = struct {
    id: []const u8,
    verified: bool,
};

pub const RaceResult = struct {
    accepted_id: ?[]const u8,
    canceled: u32,
};

pub fn race(candidates: []const FakeCandidate) !RaceResult {
    for (candidates, 0..) |candidate, i| {
        if (candidate.verified) {
            return .{
                .accepted_id = candidate.id,
                .canceled = @intCast(candidates.len - i - 1),
            };
        }
    }
    return error.NoPassingCandidate;
}

pub const EnsembleResult = struct {
    accepted_ids: []const []const u8,
};

pub fn ensemble(allocator: std.mem.Allocator, candidates: []const FakeCandidate) !EnsembleResult {
    var accepted: std.ArrayList([]const u8) = .empty;
    errdefer accepted.deinit(allocator);
    for (candidates) |candidate| {
        if (candidate.verified) try accepted.append(allocator, candidate.id);
    }
    return .{ .accepted_ids = try accepted.toOwnedSlice(allocator) };
}

pub const LoopDetector = struct {
    last_failure: ?[]const u8 = null,
};

pub fn shouldReplan(budget: *budget_mod.Budget, detector: *LoopDetector, failure: []const u8) !bool {
    if (detector.last_failure) |last| {
        if (std.mem.eql(u8, last, failure)) return false;
    }
    if (!budget.consumeReplan()) return false;
    detector.last_failure = failure;
    return true;
}

pub const ConflictInput = struct {
    had_conflict: bool,
    repair_verified: bool,
    reverified: bool,
};

pub const ConflictResult = struct {
    accepted: bool,
};

pub fn resolveConflict(input: ConflictInput) ConflictResult {
    if (!input.had_conflict) return .{ .accepted = input.reverified };
    return .{ .accepted = input.repair_verified and input.reverified };
}
