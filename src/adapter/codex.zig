const std = @import("std");
const adapter = @import("adapter.zig");
const types = @import("../core/types.zig");

pub fn profileForVersion(version: []const u8) adapter.Profile {
    if (!std.mem.eql(u8, version, "supported-1")) return unknownProfile();
    return .{
        .name = "codex",
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
        .auth_check_argv = &.{ "codex", "login", "status" },
        .known_api_key_env = &.{ "OPENAI_API_KEY", "CODEX_API_KEY" },
    };
}

pub fn buildInvocation(allocator: std.mem.Allocator, kind: adapter.ProfileKind, task: types.Task) !adapter.OwnedInvocation {
    const profile = switch (kind) {
        .supported_1 => profileForVersion("supported-1"),
        else => unknownProfile(),
    };
    if (profile.compatibility != .supported) return error.UnsupportedProfile;

    return adapter.ownInvocation(allocator, .{
        .executable = "codex",
        .argv = &.{ "codex", "exec", "--json", "--sandbox", adapter.readMode(task.role), task.instruction },
        .cwd = task.worktree_path,
        .stdin = task.context,
        .output_format = .jsonl,
    });
}

fn unknownProfile() adapter.Profile {
    return .{
        .name = "codex",
        .compatibility = .unknown,
        .capability = .{},
        .auth_check_argv = &.{ "codex", "login", "status" },
        .known_api_key_env = &.{ "OPENAI_API_KEY", "CODEX_API_KEY" },
    };
}
