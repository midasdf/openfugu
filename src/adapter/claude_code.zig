const std = @import("std");
const adapter = @import("adapter.zig");
const types = @import("../core/types.zig");

pub fn profileForVersion(version: []const u8) adapter.Profile {
    if (!std.mem.eql(u8, version, "supported-1")) return unknownProfile();
    return .{
        .name = "claude-code",
        .compatibility = .supported,
        .capability = .{
            .edit_files = true,
            .run_commands = true,
            .streaming = true,
            .structured_output = true,
            .schema_constrained_output = false,
            .read_only_mode = true,
            .workspace_write_mode = true,
            .max_context = null,
        },
        .auth_check_argv = &.{ "claude", "auth", "status" },
        .known_api_key_env = &.{"ANTHROPIC_API_KEY"},
    };
}

pub fn buildInvocation(allocator: std.mem.Allocator, kind: adapter.ProfileKind, task: types.Task) !adapter.OwnedInvocation {
    const profile = switch (kind) {
        .supported_1 => profileForVersion("supported-1"),
        else => unknownProfile(),
    };
    if (profile.compatibility != .supported) return error.UnsupportedProfile;

    const permission = adapter.readMode(task.role);
    return adapter.ownInvocation(allocator, .{
        .executable = "claude",
        .argv = &.{ "claude", "-p", task.instruction, "--output-format", "stream-json", "--permission-mode", permission },
        .cwd = task.worktree_path,
        .stdin = task.context,
        .output_format = .jsonl,
    });
}

fn unknownProfile() adapter.Profile {
    return .{
        .name = "claude-code",
        .compatibility = .unknown,
        .capability = .{},
        .auth_check_argv = &.{ "claude", "auth", "status" },
        .known_api_key_env = &.{"ANTHROPIC_API_KEY"},
    };
}
