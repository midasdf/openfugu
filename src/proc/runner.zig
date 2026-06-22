const std = @import("std");
const protocol = @import("../adapter/protocol.zig");
const session = @import("session.zig");

pub const RunSpec = struct {
    executable: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    stdout_tail_bytes: usize = 4096,
    stderr_tail_bytes: usize = 4096,
};

pub const RunResult = struct {
    exit_code: ?u8,
    signal: ?u32,
    stdout_tail: []u8,
    stderr_tail: []u8,
    events: []protocol.Event,

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

    const raw = try std.process.run(allocator, io, .{
        .argv = spec.argv,
        .cwd = .{ .path = spec.cwd },
    });
    defer allocator.free(raw.stdout);
    defer allocator.free(raw.stderr);

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
    };
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
