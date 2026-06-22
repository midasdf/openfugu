const std = @import("std");
const smoke_options = @import("smoke_options");
const openfugu = @import("openfugu");

test "real CLI smoke tests are opt-in" {
    if (!smoke_options.real_cli_tests) return error.SkipZigTest;
    const specs = [_]openfugu.probe.DetectSpec{
        .{
            .name = "claude",
            .version_argv = &.{ "claude", "--version" },
            .auth_argv = &.{ "claude", "auth", "status" },
            .supported_version = "2.",
            .profile = openfugu.claude_code.profileForVersion("2."),
            .subscription = openfugu.config.Config.default().subscription,
        },
        .{
            .name = "codex",
            .version_argv = &.{ "codex", "--version" },
            .auth_argv = &.{ "codex", "login", "status" },
            .supported_version = "codex-cli 0.141.",
            .profile = openfugu.codex.profileForVersion("codex-cli 0.141."),
            .subscription = openfugu.config.Config.default().subscription,
        },
        .{
            .name = "agy",
            .version_argv = &.{ "agy", "--version" },
            .auth_argv = &.{ "agy", "auth", "status" },
            .supported_version = "1.0.",
            .profile = openfugu.antigravity.profileForVersion("1.0."),
            .subscription = openfugu.config.Config.default().subscription,
        },
    };
    var runnable: usize = 0;
    for (specs) |spec| {
        var report = try openfugu.probe.detect(std.testing.allocator, std.testing.io, spec);
        defer report.deinit(std.testing.allocator);
        if (report.runnable) runnable += 1;
    }
    if (runnable == 0) return error.SkipZigTest;
}

test "real CLI task smoke requires second opt-in" {
    if (!smoke_options.real_cli_task_tests) return error.SkipZigTest;
    // ponytail: actual model task invocation belongs here; keep disabled unless both opt-ins are present.
}
