const std = @import("std");
const openfugu = @import("openfugu");

test "job format and parse round-trip preserves all fields" {
    const allocator = std.testing.allocator;
    const original = openfugu.jobs.Job{
        .id = "job_roundtrip",
        .status = .ok,
        .task = "fix the \"quoted\" task with \n newline and \t tab",
        .agent = "codex",
        .router = "capability",
        .route = "test_fix",
        .exit_code = 0,
        .created_ms = 1000,
        .started_ms = 2000,
        .ended_ms = 3000,
        .summary = "accepted applied reverified",
    };
    const text = try openfugu.jobs.format(allocator, original);
    defer allocator.free(text);

    var parsed = try openfugu.jobs.parse(allocator, text);
    defer openfugu.jobs.deinitJob(allocator, &parsed);

    try std.testing.expectEqualStrings(original.id, parsed.id);
    try std.testing.expectEqual(original.status, parsed.status);
    try std.testing.expectEqualStrings(original.task, parsed.task);
    try std.testing.expectEqualStrings(original.agent, parsed.agent);
    try std.testing.expectEqualStrings(original.router, parsed.router);
    try std.testing.expectEqualStrings(original.route, parsed.route);
    try std.testing.expectEqual(original.exit_code, parsed.exit_code);
    try std.testing.expectEqual(original.created_ms, parsed.created_ms);
    try std.testing.expectEqual(original.started_ms, parsed.started_ms);
    try std.testing.expectEqual(original.ended_ms, parsed.ended_ms);
    try std.testing.expectEqualStrings(original.summary, parsed.summary);
}

test "job parse tolerates unknown fields" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"id":"job_unknown","status":"running","task":"x","agent":"claude","router":"heuristic","route":"general","exit_code":null,"created_ms":10,"started_ms":20,"ended_ms":0,"summary":"","future_field":"ignored"}
    ;
    var parsed = try openfugu.jobs.parse(allocator, raw);
    defer openfugu.jobs.deinitJob(allocator, &parsed);
    try std.testing.expectEqualStrings("job_unknown", parsed.id);
    try std.testing.expectEqual(openfugu.jobs.Status.running, parsed.status);
    try std.testing.expectEqual(@as(?u8, null), parsed.exit_code);
}

test "job format escapes special characters" {
    const allocator = std.testing.allocator;
    const job = openfugu.jobs.Job{
        .id = "escape",
        .status = .queued,
        .task = "line\nbreak\ttab\"quote\\backslash",
    };
    const text = try openfugu.jobs.format(allocator, job);
    defer allocator.free(text);
    // The escaped forms must appear in the JSON output.
    try std.testing.expect(std.mem.indexOf(u8, text, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\\\") != null);
    // The raw newline must NOT appear (it must be escaped).
    try std.testing.expect(std.mem.indexOf(u8, text, "\n") == null);
}

test "status string mapping is complete" {
    const allocator = std.testing.allocator;
    const statuses = [_]openfugu.jobs.Status{ .queued, .running, .ok, .failed, .canceled };
    for (statuses) |status| {
        const job = openfugu.jobs.Job{ .id = "s", .status = status };
        const text = try openfugu.jobs.format(allocator, job);
        defer allocator.free(text);
        var parsed = try openfugu.jobs.parse(allocator, text);
        defer openfugu.jobs.deinitJob(allocator, &parsed);
        try std.testing.expectEqual(status, parsed.status);
    }
}
