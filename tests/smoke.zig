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
            .auth_argv = &.{ "agy", "models" },
            .auth_success_means_subscription = true,
            .auth_timeout_ms = 15000,
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
    if (!smoke_options.real_cli_tests or !smoke_options.real_cli_task_tests) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "repo" });
    defer std.testing.allocator.free(root);
    const worktrees = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "worktrees" });
    defer std.testing.allocator.free(worktrees);

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.createDirPath(std.testing.io, "worktrees");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/README.md", .data = "smoke\n" });
    try git(root, &.{ "init", "-b", "main" });
    try git(root, &.{ "config", "user.email", "openfugu@example.invalid" });
    try git(root, &.{ "config", "user.name", "OpenFugu Smoke" });
    try git(root, &.{ "add", "README.md" });
    try git(root, &.{ "commit", "-m", "initial" });

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
    };
    const cat_argv = [_][]const u8{ "cat", "smoke.txt" };
    var result = try openfugu.cli.runWithProbeSpecsInRepo(
        std.testing.allocator,
        std.testing.io,
        &.{ "openfugu", "--no-apply", "Create a file named smoke.txt containing exactly openfugu-smoke-ok." },
        &specs,
        root,
        worktrees,
        &.{.{ .name = "smoke-file", .argv = &cat_argv, .timeout_ms = 1000 }},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(openfugu.cli.exit_ok, result.code);
}

fn git(cwd: []const u8, args: []const []const u8) !void {
    var result = try gitOutput(cwd, args);
    defer result.deinit(std.testing.allocator);
    if (result.exit_code != 0) return error.GitFailed;
}

fn gitOutput(cwd: []const u8, args: []const []const u8) !openfugu.runner.RunResult {
    var argv = try std.testing.allocator.alloc([]const u8, args.len + 1);
    defer std.testing.allocator.free(argv);
    argv[0] = "git";
    for (args, 0..) |arg, i| argv[i + 1] = arg;

    return openfugu.runner.run(std.testing.allocator, std.testing.io, .{
        .executable = "git",
        .argv = argv,
        .cwd = cwd,
        .stdout_tail_bytes = 4096,
        .stderr_tail_bytes = 4096,
    });
}
