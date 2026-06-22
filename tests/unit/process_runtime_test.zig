const std = @import("std");
const openfugu = @import("openfugu");
const test_options = @import("test_options");

test "session rejects invalid state transitions" {
    var session = openfugu.session.Session.init("s1");

    try session.transition(.spawning);
    try session.transition(.running);
    try std.testing.expectError(error.InvalidTransition, session.transition(.created));
    try session.transition(.draining);
    try session.transition(.exited);
    try session.transition(.reaped);
}

test "runner captures stdout stderr exit code and normalized events" {
    const fake_agent = test_options.fake_agent_path;

    const argv = [_][]const u8{fake_agent};
    var result = try openfugu.runner.run(std.testing.allocator, std.testing.io, .{
        .executable = fake_agent,
        .argv = &argv,
        .cwd = ".",
        .stdout_tail_bytes = 1024,
        .stderr_tail_bytes = 1024,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout_tail, "fake out") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr_tail, "fake err") != null);
    try std.testing.expect(result.events.len >= 3);
    try std.testing.expectEqual(openfugu.protocol.EventKind.status, result.events[0].kind);
    try std.testing.expectEqual(openfugu.protocol.EventKind.final, result.events[result.events.len - 1].kind);
}

test "mux runs multiple fake agents without dropping output" {
    const fake_agent = test_options.fake_agent_path;

    const argv = [_][]const u8{fake_agent};
    const specs = [_]openfugu.runner.RunSpec{
        .{ .executable = fake_agent, .argv = &argv, .cwd = "." },
        .{ .executable = fake_agent, .argv = &argv, .cwd = "." },
    };
    const results = try openfugu.mux.runAll(std.testing.allocator, std.testing.io, &specs);
    defer openfugu.mux.freeResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |result| {
        try std.testing.expectEqual(@as(u8, 0), result.exit_code.?);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout_tail, "fake out") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr_tail, "fake err") != null);
    }
}

test "runner classifies timeout and reaps child" {
    const sleep_agent = test_options.sleep_agent_path;
    const argv = [_][]const u8{sleep_agent};

    var result = try openfugu.runner.run(std.testing.allocator, std.testing.io, .{
        .executable = sleep_agent,
        .argv = &argv,
        .cwd = ".",
        .timeout_ms = 10,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.timed_out);
    try std.testing.expect(result.exit_code == null);
    try std.testing.expect(result.signal == null);
    try std.testing.expect(result.events.len >= 2);
    try std.testing.expectEqual(openfugu.protocol.EventKind.diagnostic, result.events[result.events.len - 2].kind);
}

test "signal cancellation terminates process group and reaps child" {
    const sleep_agent = test_options.sleep_agent_path;
    const argv = [_][]const u8{sleep_agent};

    const result = try openfugu.signal.spawnThenCancel(std.testing.io, .{
        .argv = &argv,
        .cwd = ".",
        .strategy = .{ .term_grace_ms = 1, .kill_after_grace = true },
    });

    try std.testing.expect(result.term_sent);
    try std.testing.expect(result.kill_sent);
    try std.testing.expect(result.reaped);
    try std.testing.expect(result.canceled);
}

test "runner executes invocation through argv without shell" {
    const fake_agent = test_options.fake_agent_path;
    const argv = [_][]const u8{ fake_agent, "literal;not-shell" };

    var result = try openfugu.runner.runInvocation(std.testing.allocator, std.testing.io, .{
        .executable = fake_agent,
        .argv = &argv,
        .cwd = ".",
        .stdin = "",
        .env_policy = .inherit_filtered,
        .transport = .stdio,
        .output_format = .text,
    }, 1000);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout_tail, "fake out") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr_tail, "fake err") != null);
}
