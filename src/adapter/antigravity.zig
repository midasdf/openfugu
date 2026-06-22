const std = @import("std");
const adapter = @import("adapter.zig");
const types = @import("../core/types.zig");

const auth_argv = [_][]const u8{ "agy", "auth", "status" };
const api_key_env = [_][]const u8{ "GOOGLE_API_KEY", "GEMINI_API_KEY" };

pub fn profileForVersion(version: []const u8) adapter.Profile {
    if (!std.mem.eql(u8, version, "degraded-text") and !std.mem.startsWith(u8, version, "1.0.")) return unknownProfile();
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
        .auth_check_argv = &auth_argv,
        .known_api_key_env = &api_key_env,
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
        .auth_check_argv = &auth_argv,
        .known_api_key_env = &api_key_env,
    };
}
