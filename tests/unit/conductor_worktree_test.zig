const std = @import("std");
const openfugu = @import("openfugu");
const test_options = @import("test_options");

test "fake worker verifies applies and reverifies a git fixture" {
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

    const check_argv = [_][]const u8{test_options.check_file_path};
    var result = try openfugu.conductor.runFakeSingle(std.testing.allocator, .{
        .repo_path = root,
        .worktree_root = worktrees,
        .run_id = "run1",
        .candidate_id = "cand1",
        .agent_id = "fake",
        .file_path = "answer.txt",
        .replacement = "good\n",
        .io = std.testing.io,
        .verify_commands = &.{.{ .name = "check", .argv = &check_argv }},
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.accepted);
    try std.testing.expect(result.applied);
    try std.testing.expect(result.reverified);

    const applied_path = try std.fs.path.join(std.testing.allocator, &.{ root, "answer.txt" });
    defer std.testing.allocator.free(applied_path);
    const applied = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, applied_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(applied);
    try std.testing.expectEqualStrings("good\n", applied);

    var branch = try gitOutput(root, &.{ "branch", "--list", "openfugu-run1-cand1-fake" });
    defer branch.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, branch.stdout_tail, " \n\r\t"));
}

test "invocation worker runs in candidate worktree then verifies applies and reverifies" {
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
    var result = try openfugu.conductor.runInvocationSingle(std.testing.allocator, .{
        .repo_path = root,
        .worktree_root = worktrees,
        .run_id = "run-invoke",
        .candidate_id = "cand-invoke",
        .agent_id = "fake",
        .invocation = .{
            .executable = test_options.write_file_agent_path,
            .argv = &worker_argv,
            .cwd = ".",
        },
        .timeout_ms = 1000,
        .io = std.testing.io,
        .verify_commands = &.{.{ .name = "check", .argv = &check_argv }},
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.accepted);
    try std.testing.expect(result.applied);
    try std.testing.expect(result.reverified);

    const applied_path = try std.fs.path.join(std.testing.allocator, &.{ root, "answer.txt" });
    defer std.testing.allocator.free(applied_path);
    const applied = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, applied_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(applied);
    try std.testing.expectEqualStrings("good\n", applied);

    var branch = try gitOutput(root, &.{ "branch", "--list", "openfugu-run-invoke-cand-invoke-fake" });
    defer branch.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, branch.stdout_tail, " \n\r\t"));
}

test "required model review rejection blocks apply after objective verification" {
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
    var result = try openfugu.conductor.runInvocationSingle(std.testing.allocator, .{
        .repo_path = root,
        .worktree_root = worktrees,
        .run_id = "run-review",
        .candidate_id = "cand-review",
        .agent_id = "fake",
        .invocation = .{
            .executable = test_options.write_file_agent_path,
            .argv = &worker_argv,
            .cwd = ".",
        },
        .timeout_ms = 1000,
        .io = std.testing.io,
        .verify_commands = &.{.{ .name = "check", .argv = &check_argv }},
        .model_review = .{ .required = true, .rejected = true, .summary = "serious bug" },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.accepted);
    try std.testing.expect(!result.applied);
    try std.testing.expect(!result.reverified);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "answer.txt" });
    defer std.testing.allocator.free(source_path);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, source_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings("bad\n", source);
}

test "workspace cleanup removes candidate worktree and branch" {
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/answer.txt", .data = "ok\n" });
    try git(root, &.{ "init", "-b", "main" });
    try git(root, &.{ "config", "user.email", "openfugu@example.invalid" });
    try git(root, &.{ "config", "user.name", "OpenFugu Test" });
    try git(root, &.{ "add", "answer.txt" });
    try git(root, &.{ "commit", "-m", "initial" });

    var snap = try openfugu.workspace.snapshot(std.testing.allocator, std.testing.io, root);
    defer snap.deinit(std.testing.allocator);
    var candidate = try openfugu.workspace.createCandidate(std.testing.allocator, std.testing.io, snap, worktrees, "run2", "cand2", "fake");
    defer candidate.deinit(std.testing.allocator);

    try openfugu.workspace.cleanupCandidate(std.testing.allocator, std.testing.io, root, candidate);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, candidate.worktree_path, .{}));
    var branch = try gitOutput(root, &.{ "branch", "--list", candidate.branch });
    defer branch.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, branch.stdout_tail, " \n\r\t"));
}

test "workspace patch captures candidate diff from git" {
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

    var snap = try openfugu.workspace.snapshot(std.testing.allocator, std.testing.io, root);
    defer snap.deinit(std.testing.allocator);
    var candidate = try openfugu.workspace.createCandidate(std.testing.allocator, std.testing.io, snap, worktrees, "run3", "cand3", "fake");
    defer candidate.deinit(std.testing.allocator);

    try openfugu.workspace.writeFile(std.testing.allocator, std.testing.io, candidate.worktree_path, "answer.txt", "good\n");
    try openfugu.workspace.commitAll(std.testing.allocator, std.testing.io, &candidate, "candidate");

    var patch = try openfugu.patch.capture(std.testing.allocator, std.testing.io, candidate.worktree_path, snap.head, candidate.commit.?);
    defer patch.deinit(std.testing.allocator);

    try std.testing.expect(patch.has_changes);
    try std.testing.expect(std.mem.indexOf(u8, patch.text, "-bad") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch.text, "+good") != null);
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
