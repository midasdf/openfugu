const std = @import("std");
const runner = @import("../proc/runner.zig");

pub const Command = struct {
    name: []const u8,
    argv: []const []const u8,
    timeout_ms: ?i64 = null,
    log_path: ?[]const u8 = null,
};

pub const CommandResult = struct {
    name: []const u8,
    exit_code: ?u8,
    signal: ?u32 = null,
    timed_out: bool = false,
    canceled: bool = false,
    log_path: ?[]u8 = null,
    started_ms: i64 = 0,
    ended_ms: i64 = 0,
    stdout_tail: []u8,
    stderr_tail: []u8,

    pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        if (self.log_path) |path| allocator.free(path);
        allocator.free(self.stdout_tail);
        allocator.free(self.stderr_tail);
        self.* = undefined;
    }
};

pub const Verification = struct {
    passed: bool,
    unverified: bool,
    commands: []CommandResult,

    pub fn deinit(self: *Verification, allocator: std.mem.Allocator) void {
        for (self.commands) |*command| command.deinit(allocator);
        allocator.free(self.commands);
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, commands: []const Command) !Verification {
    if (commands.len == 0) {
        return .{
            .passed = false,
            .unverified = true,
            .commands = try allocator.alloc(CommandResult, 0),
        };
    }

    const results = try allocator.alloc(CommandResult, commands.len);
    errdefer allocator.free(results);

    var filled: usize = 0;
    errdefer {
        for (results[0..filled]) |*result| result.deinit(allocator);
    }

    var passed = true;
    for (commands, 0..) |command, i| {
        const started_ms = nowMs(io);
        var raw = try runner.run(allocator, io, .{
            .executable = command.argv[0],
            .argv = command.argv,
            .cwd = cwd,
            .stdout_tail_bytes = 4096,
            .stderr_tail_bytes = 4096,
            .timeout_ms = command.timeout_ms,
            .log_path = command.log_path,
        });
        const ended_ms = nowMs(io);
        defer raw.deinit(allocator);

        results[i] = .{
            .name = command.name,
            .exit_code = raw.exit_code,
            .signal = raw.signal,
            .timed_out = raw.timed_out,
            .canceled = raw.canceled,
            .log_path = if (command.log_path) |path| try allocator.dupe(u8, path) else null,
            .started_ms = started_ms,
            .ended_ms = ended_ms,
            .stdout_tail = try allocator.dupe(u8, raw.stdout_tail),
            .stderr_tail = try allocator.dupe(u8, raw.stderr_tail),
        };
        filled += 1;
        if (raw.exit_code != 0 or raw.signal != null or raw.timed_out or raw.canceled) passed = false;
    }

    return .{
        .passed = passed,
        .unverified = false,
        .commands = results,
    };
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}
