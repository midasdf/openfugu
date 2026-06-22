const std = @import("std");
const openfugu = @import("openfugu");
const test_options = @import("test_options");

test "probe detects version subscription auth and runnable status" {
    var report = try openfugu.probe.detect(std.testing.allocator, std.testing.io, .{
        .name = "claude",
        .version_argv = &.{ test_options.probe_cli_path, "--version" },
        .auth_argv = &.{ test_options.probe_cli_path, "auth" },
        .supported_version = "supported-1",
        .profile = openfugu.claude_code.profileForVersion("supported-1"),
        .subscription = openfugu.config.Config.default().subscription,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.exists);
    try std.testing.expectEqualStrings("supported-1", report.version);
    try std.testing.expectEqual(openfugu.types.AuthKind.subscription, report.auth);
    try std.testing.expectEqual(openfugu.types.Compatibility.supported, report.compatibility);
    try std.testing.expect(report.non_interactive);
    try std.testing.expect(report.structured_output);
    try std.testing.expect(report.runnable);
}

test "probe rejects api key auth under subscription only" {
    var report = try openfugu.probe.detect(std.testing.allocator, std.testing.io, .{
        .name = "claude",
        .version_argv = &.{ test_options.probe_cli_path, "--version" },
        .auth_argv = &.{ test_options.probe_cli_path, "apikey" },
        .supported_version = "supported-1",
        .profile = openfugu.claude_code.profileForVersion("supported-1"),
        .subscription = openfugu.config.Config.default().subscription,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(openfugu.types.AuthKind.api_key, report.auth);
    try std.testing.expect(!report.runnable);
}

test "doctor cli uses probe specs instead of static unknown reports" {
    const specs = [_]openfugu.probe.DetectSpec{.{
        .name = "claude",
        .version_argv = &.{ test_options.probe_cli_path, "--version" },
        .auth_argv = &.{ test_options.probe_cli_path, "auth" },
        .supported_version = "supported-1",
        .profile = openfugu.claude_code.profileForVersion("supported-1"),
        .subscription = openfugu.config.Config.default().subscription,
    }};

    var result = try openfugu.cli.runWithProbeSpecs(std.testing.allocator, std.testing.io, &.{ "openfugu", "doctor" }, &specs);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(openfugu.cli.exit_ok, result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "claude exists=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "version=supported-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "auth=subscription") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "runnable=true") != null);
}

test "task cli runs probed subscription agent through verify apply reverify" {
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/answer.txt", .data = "bad\n" });
    try git(root, &.{ "init", "-b", "main" });
    try git(root, &.{ "config", "user.email", "openfugu@example.invalid" });
    try git(root, &.{ "config", "user.name", "OpenFugu Test" });
    try git(root, &.{ "add", "answer.txt" });
    try git(root, &.{ "commit", "-m", "initial" });

    const worker_argv = [_][]const u8{ test_options.write_file_agent_path, "answer.txt", "good\n" };
    const check_argv = [_][]const u8{test_options.check_file_path};
    const specs = [_]openfugu.probe.DetectSpec{.{
        .name = "fake",
        .version_argv = &.{ test_options.probe_cli_path, "--version" },
        .auth_argv = &.{ test_options.probe_cli_path, "auth" },
        .task_argv = &worker_argv,
        .supported_version = "supported-1",
        .profile = openfugu.claude_code.profileForVersion("supported-1"),
        .subscription = openfugu.config.Config.default().subscription,
    }};

    var result = try openfugu.cli.runWithProbeSpecsInRepo(
        std.testing.allocator,
        std.testing.io,
        &.{ "openfugu", "fix bug" },
        &specs,
        root,
        worktrees,
        &.{.{ .name = "check", .argv = &check_argv }},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(openfugu.cli.exit_ok, result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "agent=fake") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "accepted=true") != null);

    const applied_path = try std.fs.path.join(std.testing.allocator, &.{ root, "answer.txt" });
    defer std.testing.allocator.free(applied_path);
    const applied = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, applied_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(applied);
    try std.testing.expectEqualStrings("good\n", applied);
}

test "task cli no-apply verifies candidate without changing source repo" {
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/answer.txt", .data = "bad\n" });
    try git(root, &.{ "init", "-b", "main" });
    try git(root, &.{ "config", "user.email", "openfugu@example.invalid" });
    try git(root, &.{ "config", "user.name", "OpenFugu Test" });
    try git(root, &.{ "add", "answer.txt" });
    try git(root, &.{ "commit", "-m", "initial" });

    const worker_argv = [_][]const u8{ test_options.write_file_agent_path, "answer.txt", "good\n" };
    const check_argv = [_][]const u8{test_options.check_file_path};
    const specs = [_]openfugu.probe.DetectSpec{.{
        .name = "fake",
        .version_argv = &.{ test_options.probe_cli_path, "--version" },
        .auth_argv = &.{ test_options.probe_cli_path, "auth" },
        .task_argv = &worker_argv,
        .supported_version = "supported-1",
        .profile = openfugu.claude_code.profileForVersion("supported-1"),
        .subscription = openfugu.config.Config.default().subscription,
    }};

    var result = try openfugu.cli.runWithProbeSpecsInRepo(
        std.testing.allocator,
        std.testing.io,
        &.{ "openfugu", "--no-apply", "fix bug" },
        &specs,
        root,
        worktrees,
        &.{.{ .name = "check", .argv = &check_argv }},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(openfugu.cli.exit_ok, result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "accepted=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "applied=false") != null);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "answer.txt" });
    defer std.testing.allocator.free(source_path);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, source_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings("bad\n", source);
}

test "task cli honors agents filter" {
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/answer.txt", .data = "bad\n" });
    try git(root, &.{ "init", "-b", "main" });
    try git(root, &.{ "config", "user.email", "openfugu@example.invalid" });
    try git(root, &.{ "config", "user.name", "OpenFugu Test" });
    try git(root, &.{ "add", "answer.txt" });
    try git(root, &.{ "commit", "-m", "initial" });

    const worker_argv = [_][]const u8{ test_options.write_file_agent_path, "answer.txt", "good\n" };
    const check_argv = [_][]const u8{test_options.check_file_path};
    const specs = [_]openfugu.probe.DetectSpec{
        .{
            .name = "skipme",
            .version_argv = &.{ test_options.probe_cli_path, "--version" },
            .auth_argv = &.{ test_options.probe_cli_path, "auth" },
            .task_argv = &worker_argv,
            .supported_version = "supported-1",
            .profile = openfugu.claude_code.profileForVersion("supported-1"),
            .subscription = openfugu.config.Config.default().subscription,
        },
        .{
            .name = "pickme",
            .version_argv = &.{ test_options.probe_cli_path, "--version" },
            .auth_argv = &.{ test_options.probe_cli_path, "auth" },
            .task_argv = &worker_argv,
            .supported_version = "supported-1",
            .profile = openfugu.claude_code.profileForVersion("supported-1"),
            .subscription = openfugu.config.Config.default().subscription,
        },
    };

    var result = try openfugu.cli.runWithProbeSpecsInRepo(
        std.testing.allocator,
        std.testing.io,
        &.{ "openfugu", "--agents", "pickme", "fix bug" },
        &specs,
        root,
        worktrees,
        &.{.{ .name = "check", .argv = &check_argv }},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(openfugu.cli.exit_ok, result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "agent=pickme") != null);
}

test "task cli race tries next runnable candidate after verification failure" {
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/answer.txt", .data = "bad\n" });
    try git(root, &.{ "init", "-b", "main" });
    try git(root, &.{ "config", "user.email", "openfugu@example.invalid" });
    try git(root, &.{ "config", "user.name", "OpenFugu Test" });
    try git(root, &.{ "add", "answer.txt" });
    try git(root, &.{ "commit", "-m", "initial" });

    const bad_worker_argv = [_][]const u8{ test_options.write_file_agent_path, "answer.txt", "wrong\n" };
    const good_worker_argv = [_][]const u8{ test_options.write_file_agent_path, "answer.txt", "good\n" };
    const check_argv = [_][]const u8{test_options.check_file_path};
    const specs = [_]openfugu.probe.DetectSpec{
        .{
            .name = "bad",
            .version_argv = &.{ test_options.probe_cli_path, "--version" },
            .auth_argv = &.{ test_options.probe_cli_path, "auth" },
            .task_argv = &bad_worker_argv,
            .supported_version = "supported-1",
            .profile = openfugu.claude_code.profileForVersion("supported-1"),
            .subscription = openfugu.config.Config.default().subscription,
        },
        .{
            .name = "good",
            .version_argv = &.{ test_options.probe_cli_path, "--version" },
            .auth_argv = &.{ test_options.probe_cli_path, "auth" },
            .task_argv = &good_worker_argv,
            .supported_version = "supported-1",
            .profile = openfugu.claude_code.profileForVersion("supported-1"),
            .subscription = openfugu.config.Config.default().subscription,
        },
    };

    var result = try openfugu.cli.runWithProbeSpecsInRepo(
        std.testing.allocator,
        std.testing.io,
        &.{ "openfugu", "--mode", "race", "fix bug" },
        &specs,
        root,
        worktrees,
        &.{.{ .name = "check", .argv = &check_argv }},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(openfugu.cli.exit_ok, result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "agent=good") != null);
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
