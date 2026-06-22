const std = @import("std");
const builtin = @import("builtin");

pub const CancelStrategy = struct {
    term_grace_ms: u64 = 1000,
    kill_after_grace: bool = true,
};

pub const CancelSpec = struct {
    argv: []const []const u8,
    cwd: []const u8 = ".",
    strategy: CancelStrategy = .{},
};

pub const CancelResult = struct {
    term_sent: bool,
    kill_sent: bool,
    reaped: bool,
    canceled: bool,
    signal: ?u32,
};

pub fn spawnThenCancel(io: std.Io, spec: CancelSpec) !CancelResult {
    var child = try std.process.spawn(io, .{
        .argv = spec.argv,
        .cwd = .{ .path = spec.cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    defer child.kill(io);

    const term_sent = signalChildGroup(child, .TERM);
    const grace_ms = @min(spec.strategy.term_grace_ms, @as(u64, @intCast(std.math.maxInt(i64))));
    try io.sleep(std.Io.Duration.fromMilliseconds(@intCast(grace_ms)), .awake);
    const kill_sent = if (spec.strategy.kill_after_grace) signalChildGroup(child, .KILL) else false;
    const term = try child.wait(io);

    return .{
        .term_sent = term_sent,
        .kill_sent = kill_sent,
        .reaped = true,
        .canceled = term_sent or kill_sent,
        .signal = exitSignal(term),
    };
}

fn signalChildGroup(child: std.process.Child, sig: std.posix.SIG) bool {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return false;
    const pid = child.id orelse return false;
    std.posix.kill(-pid, sig) catch {
        std.posix.kill(pid, sig) catch return false;
    };
    return true;
}

fn exitSignal(term: std.process.Child.Term) ?u32 {
    return switch (term) {
        .signal => |sig| @intFromEnum(sig),
        else => null,
    };
}
