const std = @import("std");
const protocol = @import("../adapter/protocol.zig");
const session = @import("session.zig");
const types = @import("../core/types.zig");
const environment = @import("environment.zig");

pub const RunSpec = struct {
    executable: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    stdout_tail_bytes: usize = 4096,
    stderr_tail_bytes: usize = 4096,
    timeout_ms: ?i64 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    log_path: ?[]const u8 = null,
};

pub const RunResult = struct {
    exit_code: ?u8,
    signal: ?u32,
    stdout_tail: []u8,
    stderr_tail: []u8,
    events: []protocol.Event,
    timed_out: bool = false,
    canceled: bool = false,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout_tail);
        allocator.free(self.stderr_tail);
        protocol.freeEvents(allocator, self.events);
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, spec: RunSpec) !RunResult {
    var s = session.Session.init("run");
    try s.transition(.spawning);
    try s.transition(.running);

    const raw = std.process.run(allocator, io, .{
        .argv = spec.argv,
        .cwd = .{ .path = spec.cwd },
        .timeout = timeoutFromMs(spec.timeout_ms),
        .environ_map = spec.environ_map,
    }) catch |err| switch (err) {
        error.Timeout => {
            try s.transition(.timed_out);
            try s.transition(.reaped);
            const events = try protocol.cloneEvents(allocator, &.{
                .{ .kind = .status, .text = "spawned" },
                .{ .kind = .diagnostic, .text = "timed_out" },
                .{ .kind = .final, .text = "reaped" },
            });
            errdefer protocol.freeEvents(allocator, events);
            return .{
                .exit_code = null,
                .signal = null,
                .stdout_tail = try allocator.alloc(u8, 0),
                .stderr_tail = try allocator.alloc(u8, 0),
                .events = events,
                .timed_out = true,
                .canceled = false,
            };
        },
        else => |e| return e,
    };
    defer allocator.free(raw.stdout);
    defer allocator.free(raw.stderr);
    try writeLog(io, spec.log_path, raw.stdout, raw.stderr);

    try s.transition(.draining);
    try s.transition(.exited);
    try s.transition(.reaped);

    const events = try protocol.cloneEvents(allocator, &.{
        .{ .kind = .status, .text = "spawned" },
        .{ .kind = .diagnostic, .text = "captured" },
        .{ .kind = .final, .text = "reaped" },
    });
    errdefer protocol.freeEvents(allocator, events);

    return .{
        .exit_code = exitCode(raw.term),
        .signal = exitSignal(raw.term),
        .stdout_tail = try tail(allocator, raw.stdout, spec.stdout_tail_bytes),
        .stderr_tail = try tail(allocator, raw.stderr, spec.stderr_tail_bytes),
        .events = events,
        .timed_out = false,
        .canceled = false,
    };
}

pub fn runInvocation(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: types.Invocation,
    timeout_ms: u64,
) !RunResult {
    if (invocation.stdin.len != 0) {
        return runInvocationWithStdin(allocator, io, invocation, timeout_ms);
    }
    return run(allocator, io, .{
        .executable = invocation.executable,
        .argv = invocation.argv,
        .cwd = invocation.cwd,
        .timeout_ms = timeoutFromUnsignedMs(timeout_ms),
    });
}

pub fn runInvocationWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: types.Invocation,
    timeout_ms: u64,
    parent_env: *const std.process.Environ.Map,
) !RunResult {
    var child_env = switch (invocation.env_policy) {
        .inherit_filtered => try parent_env.clone(allocator),
        .empty => std.process.Environ.Map.init(allocator),
    };
    defer child_env.deinit();

    if (invocation.env_policy == .inherit_filtered) environment.stripKnownApiKeys(&child_env);

    return run(allocator, io, .{
        .executable = invocation.executable,
        .argv = invocation.argv,
        .cwd = invocation.cwd,
        .timeout_ms = timeoutFromUnsignedMs(timeout_ms),
        .environ_map = &child_env,
    });
}

fn timeoutFromMs(timeout_ms: ?i64) std.Io.Timeout {
    const ms = timeout_ms orelse return .none;
    return .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(ms),
        .clock = .awake,
    } };
}

fn runInvocationWithStdin(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: types.Invocation,
    timeout_ms: u64,
) !RunResult {
    var s = session.Session.init("run");
    try s.transition(.spawning);
    try s.transition(.running);

    var child = try std.process.spawn(io, .{
        .argv = invocation.argv,
        .cwd = .{ .path = invocation.cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    try child.stdin.?.writeStreamingAll(io, invocation.stdin);
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    _ = multi_reader.reader(0);
    _ = multi_reader.reader(1);
    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(timeoutFromUnsignedMs(timeout_ms)),
        .clock = .awake,
    } };

    while (multi_reader.fill(64, timeout)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => {
            try s.transition(.timed_out);
            try s.transition(.reaped);
            const events = try protocol.cloneEvents(allocator, &.{
                .{ .kind = .status, .text = "spawned" },
                .{ .kind = .diagnostic, .text = "timed_out" },
                .{ .kind = .final, .text = "reaped" },
            });
            errdefer protocol.freeEvents(allocator, events);
            return .{
                .exit_code = null,
                .signal = null,
                .stdout_tail = try allocator.alloc(u8, 0),
                .stderr_tail = try allocator.alloc(u8, 0),
                .events = events,
                .timed_out = true,
                .canceled = false,
            };
        },
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    defer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    defer allocator.free(stderr);

    try s.transition(.draining);
    try s.transition(.exited);
    try s.transition(.reaped);

    const events = try protocol.cloneEvents(allocator, &.{
        .{ .kind = .status, .text = "spawned" },
        .{ .kind = .diagnostic, .text = "captured" },
        .{ .kind = .final, .text = "reaped" },
    });
    errdefer protocol.freeEvents(allocator, events);

    return .{
        .exit_code = exitCode(term),
        .signal = exitSignal(term),
        .stdout_tail = try tail(allocator, stdout, 4096),
        .stderr_tail = try tail(allocator, stderr, 4096),
        .events = events,
        .timed_out = false,
        .canceled = false,
    };
}

fn writeLog(io: std.Io, log_path: ?[]const u8, stdout: []const u8, stderr: []const u8) !void {
    const path = log_path orelse return;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(stdout);
    try writer.interface.writeAll(stderr);
    try writer.interface.flush();
}

fn timeoutFromUnsignedMs(timeout_ms: u64) i64 {
    return @intCast(@min(timeout_ms, @as(u64, @intCast(std.math.maxInt(i64)))));
}

fn tail(allocator: std.mem.Allocator, bytes: []const u8, max: usize) ![]u8 {
    const start = if (bytes.len > max) bytes.len - max else 0;
    return allocator.dupe(u8, bytes[start..]);
}

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

fn exitSignal(term: std.process.Child.Term) ?u32 {
    return switch (term) {
        .signal => |sig| @intFromEnum(sig),
        else => null,
    };
}
