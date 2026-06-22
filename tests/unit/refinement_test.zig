const std = @import("std");
const openfugu = @import("openfugu");

test "race accepts first passing candidate and cancels remaining" {
    const candidates = [_]openfugu.refinement.FakeCandidate{
        .{ .id = "a", .verified = false },
        .{ .id = "b", .verified = true },
        .{ .id = "c", .verified = true },
    };

    const result = try openfugu.refinement.race(&candidates);
    try std.testing.expectEqualStrings("b", result.accepted_id.?);
    try std.testing.expectEqual(@as(u32, 1), result.canceled);
}

test "ensemble excludes failing candidates before synthesis" {
    const candidates = [_]openfugu.refinement.FakeCandidate{
        .{ .id = "bad", .verified = false },
        .{ .id = "good", .verified = true },
    };

    const result = try openfugu.refinement.ensemble(std.testing.allocator, &candidates);
    defer std.testing.allocator.free(result.accepted_ids);

    try std.testing.expectEqual(@as(usize, 1), result.accepted_ids.len);
    try std.testing.expectEqualStrings("good", result.accepted_ids[0]);
}

test "refinement consumes shared budget and stops repeated failures" {
    var budget = openfugu.budget.Budget{ .max_depth = 2, .remaining_agent_calls = 2 };
    var detector = openfugu.refinement.LoopDetector{};

    try std.testing.expect(try openfugu.refinement.shouldReplan(&budget, &detector, "same failure"));
    try std.testing.expect(!try openfugu.refinement.shouldReplan(&budget, &detector, "same failure"));
    try std.testing.expectEqual(@as(u32, 1), budget.remaining_agent_calls);
}

test "conflict repair requires reverification before acceptance" {
    const repaired = openfugu.refinement.resolveConflict(.{
        .had_conflict = true,
        .repair_verified = true,
        .reverified = true,
    });
    try std.testing.expect(repaired.accepted);

    const not_reverified = openfugu.refinement.resolveConflict(.{
        .had_conflict = true,
        .repair_verified = true,
        .reverified = false,
    });
    try std.testing.expect(!not_reverified.accepted);
}
