const std = @import("std");
const runner = @import("../proc/runner.zig");

pub const PatchSummary = struct {
    has_changes: bool,
};

pub const Patch = struct {
    has_changes: bool,
    text: []u8,

    pub fn deinit(self: *Patch, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn capture(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8, base_ref: []const u8, head_ref: []const u8) !Patch {
    const argv = [_][]const u8{ "git", "diff", "--binary", base_ref, head_ref };
    var result = try runner.run(allocator, io, .{
        .executable = "git",
        .argv = &argv,
        .cwd = repo_path,
        .stdout_tail_bytes = 1024 * 1024,
        .stderr_tail_bytes = 4096,
    });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.GitFailed;

    return .{
        .has_changes = std.mem.trim(u8, result.stdout_tail, " \n\r\t").len != 0,
        .text = try allocator.dupe(u8, result.stdout_tail),
    };
}
