const std = @import("std");
const runner = @import("../proc/runner.zig");

pub const Command = struct {
    name: []const u8,
    argv: []const []const u8,
};

pub const CommandResult = struct {
    name: []const u8,
    exit_code: ?u8,
    stdout_tail: []u8,
    stderr_tail: []u8,

    pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
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
        var raw = try runner.run(allocator, io, .{
            .executable = command.argv[0],
            .argv = command.argv,
            .cwd = cwd,
            .stdout_tail_bytes = 4096,
            .stderr_tail_bytes = 4096,
        });
        defer raw.deinit(allocator);

        results[i] = .{
            .name = command.name,
            .exit_code = raw.exit_code,
            .stdout_tail = try allocator.dupe(u8, raw.stdout_tail),
            .stderr_tail = try allocator.dupe(u8, raw.stderr_tail),
        };
        filled += 1;
        if (raw.exit_code != 0) passed = false;
    }

    return .{
        .passed = passed,
        .unverified = false,
        .commands = results,
    };
}
