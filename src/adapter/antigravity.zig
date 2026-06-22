const std = @import("std");
const adapter = @import("adapter.zig");
const types = @import("../core/types.zig");

pub fn profileForVersion(version: []const u8) adapter.Profile {
    if (!std.mem.eql(u8, version, "degraded-text")) return unknownProfile();
    return .{
        .name = "antigravity",
        .compatibility = .degraded,
        .capability = .{
            .edit_files = true,
            .run_commands = true,
            .streaming = false,
            .structured_output = false,
            .schema_constrained_output = false,
            .read_only_mode = false,
            .workspace_write_mode = true,
            .max_context = null,
        },
        .auth_check_argv = &.{ "agy", "auth", "status" },
        .known_api_key_env = &.{ "GOOGLE_API_KEY", "GEMINI_API_KEY" },
    };
}

pub fn buildInvocation(allocator: std.mem.Allocator, kind: adapter.ProfileKind, task: types.Task) !adapter.OwnedInvocation {
    const profile = switch (kind) {
        .degraded_text => profileForVersion("degraded-text"),
        else => unknownProfile(),
    };
    if (profile.compatibility != .degraded) return error.UnsupportedProfile;

    return adapter.ownInvocation(allocator, .{
        .executable = "agy",
        .argv = &.{ "agy", "-p", task.instruction },
        .cwd = task.worktree_path,
        .stdin = task.context,
        .output_format = .text,
    });
}

fn unknownProfile() adapter.Profile {
    return .{
        .name = "antigravity",
        .compatibility = .unknown,
        .capability = .{},
        .auth_check_argv = &.{ "agy", "auth", "status" },
        .known_api_key_env = &.{ "GOOGLE_API_KEY", "GEMINI_API_KEY" },
    };
}
