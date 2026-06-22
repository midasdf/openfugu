const std = @import("std");
const adapter = @import("adapter.zig");
const types = @import("../core/types.zig");

const auth_argv = [_][]const u8{ "claude", "auth", "status" };
const api_key_env = [_][]const u8{"ANTHROPIC_API_KEY"};

pub fn profileForVersion(version: []const u8) adapter.Profile {
    if (!std.mem.eql(u8, version, "supported-1") and !std.mem.startsWith(u8, version, "2.")) return unknownProfile();
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
        .auth_check_argv = &auth_argv,
        .known_api_key_env = &api_key_env,
    };
}

pub fn buildInvocation(allocator: std.mem.Allocator, kind: adapter.ProfileKind, task: types.Task) !adapter.OwnedInvocation {
    const profile = switch (kind) {
        .supported_1 => profileForVersion("supported-1"),
        else => unknownProfile(),
    };
    if (profile.compatibility != .supported) return error.UnsupportedProfile;

    const permission = claudePermissionMode(task.role);
    return adapter.ownInvocation(allocator, .{
        .executable = "claude",
        .argv = &.{ "claude", "-p", task.instruction, "--output-format", "stream-json", "--verbose", "--permission-mode", permission },
        .cwd = task.worktree_path,
        .stdin = task.context,
        .output_format = .jsonl,
    });
}

fn claudePermissionMode(role: types.Role) []const u8 {
    return switch (role) {
        .thinker, .verifier => "plan",
        .worker => "acceptEdits",
    };
}

fn unknownProfile() adapter.Profile {
    return .{
        .name = "claude-code",
        .compatibility = .unknown,
        .capability = .{},
        .auth_check_argv = &auth_argv,
        .known_api_key_env = &api_key_env,
    };
}
