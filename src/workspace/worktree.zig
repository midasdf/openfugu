const std = @import("std");
const runner = @import("../proc/runner.zig");

pub const Snapshot = struct {
    repo_path: []const u8,
    head: []u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.head);
        self.* = undefined;
    }
};

pub const Candidate = struct {
    worktree_path: []u8,
    branch: []u8,
    commit: ?[]u8 = null,

    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.worktree_path);
        allocator.free(self.branch);
        if (self.commit) |commit| allocator.free(commit);
        self.* = undefined;
    }
};

pub fn snapshot(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8) !Snapshot {
    try requireClean(allocator, io, repo_path);
    var result = try runGit(allocator, io, repo_path, &.{ "rev-parse", "HEAD" });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.GitFailed;
    return .{
        .repo_path = repo_path,
        .head = try trimDupe(allocator, result.stdout_tail),
    };
}

pub fn createCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    snap: Snapshot,
    worktree_root: []const u8,
    run_id: []const u8,
    candidate_id: []const u8,
    agent_id: []const u8,
) !Candidate {
    const name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ run_id, candidate_id, agent_id });
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ worktree_root, name });
    errdefer allocator.free(path);
    const branch = try std.fmt.allocPrint(allocator, "openfugu-{s}-{s}-{s}", .{ run_id, candidate_id, agent_id });
    errdefer allocator.free(branch);

    var result = try runGit(allocator, io, snap.repo_path, &.{ "worktree", "add", "-b", branch, path, snap.head });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.WorktreeCreateFailed;

    return .{ .worktree_path = path, .branch = branch };
}

pub fn writeFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, relative: []const u8, data: []const u8) !void {
    const full = try std.fs.path.join(allocator, &.{ path, relative });
    defer allocator.free(full);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = data });
}

pub fn commitAll(allocator: std.mem.Allocator, io: std.Io, candidate: *Candidate, message: []const u8) !void {
    var add = try runGit(allocator, io, candidate.worktree_path, &.{ "add", "-A" });
    defer add.deinit(allocator);
    if (add.exit_code != 0) return error.GitFailed;

    if (!try hasChanges(allocator, io, candidate.worktree_path)) return error.NoCandidateChanges;

    var commit = try runGit(allocator, io, candidate.worktree_path, &.{ "commit", "-m", message });
    defer commit.deinit(allocator);
    if (commit.exit_code != 0) return error.GitFailed;

    var head = try runGit(allocator, io, candidate.worktree_path, &.{ "rev-parse", "HEAD" });
    defer head.deinit(allocator);
    if (head.exit_code != 0) return error.GitFailed;
    candidate.commit = try trimDupe(allocator, head.stdout_tail);
}

pub fn applyNoCommit(allocator: std.mem.Allocator, io: std.Io, snap: Snapshot, candidate: Candidate) !void {
    try requireClean(allocator, io, snap.repo_path);

    var head = try runGit(allocator, io, snap.repo_path, &.{ "rev-parse", "HEAD" });
    defer head.deinit(allocator);
    if (head.exit_code != 0) return error.GitFailed;
    const current = try trimDupe(allocator, head.stdout_tail);
    defer allocator.free(current);
    if (!std.mem.eql(u8, current, snap.head)) return error.SourceHeadChanged;

    const commit = candidate.commit orelse return error.NoCandidateCommit;
    var pick = try runGit(allocator, io, snap.repo_path, &.{ "cherry-pick", "--no-commit", commit });
    defer pick.deinit(allocator);
    if (pick.exit_code != 0) return error.ApplyFailed;
}

pub fn cleanupCandidate(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8, candidate: Candidate) !void {
    var remove = try runGit(allocator, io, repo_path, &.{ "worktree", "remove", "--force", candidate.worktree_path });
    defer remove.deinit(allocator);
    if (remove.exit_code != 0) return error.WorktreeCleanupFailed;

    var branch = try runGit(allocator, io, repo_path, &.{ "branch", "-D", candidate.branch });
    defer branch.deinit(allocator);
    if (branch.exit_code != 0) return error.BranchCleanupFailed;
}

fn requireClean(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8) !void {
    var result = try runGit(allocator, io, repo_path, &.{ "status", "--porcelain" });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.GitFailed;
    if (std.mem.trim(u8, result.stdout_tail, " \n\r\t").len != 0) return error.SourceNotClean;
}

fn hasChanges(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8) !bool {
    var result = try runGit(allocator, io, repo_path, &.{ "status", "--porcelain" });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.GitFailed;
    return std.mem.trim(u8, result.stdout_tail, " \n\r\t").len != 0;
}

fn runGit(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) !runner.RunResult {
    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = "git";
    for (args, 0..) |arg, i| argv[i + 1] = arg;
    return runner.run(allocator, io, .{
        .executable = "git",
        .argv = argv,
        .cwd = cwd,
        .stdout_tail_bytes = 8192,
        .stderr_tail_bytes = 8192,
    });
}

fn trimDupe(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return allocator.dupe(u8, std.mem.trim(u8, bytes, " \n\r\t"));
}
