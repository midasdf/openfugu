const std = @import("std");
const verify = @import("../verify/commands.zig");
const workspace = @import("../workspace/worktree.zig");

pub const FakeSingleRequest = struct {
    repo_path: []const u8,
    worktree_root: []const u8,
    run_id: []const u8,
    candidate_id: []const u8,
    agent_id: []const u8,
    file_path: []const u8,
    replacement: []const u8,
    io: std.Io,
    verify_commands: []const verify.Command,
};

pub const RunSummary = struct {
    accepted: bool,
    applied: bool,
    reverified: bool,
    candidate_verification: verify.Verification,
    final_verification: verify.Verification,

    pub fn deinit(self: *RunSummary, allocator: std.mem.Allocator) void {
        self.candidate_verification.deinit(allocator);
        self.final_verification.deinit(allocator);
        self.* = undefined;
    }
};

pub fn runFakeSingle(allocator: std.mem.Allocator, req: FakeSingleRequest) !RunSummary {
    var snap = try workspace.snapshot(allocator, req.io, req.repo_path);
    defer snap.deinit(allocator);

    var candidate = try workspace.createCandidate(
        allocator,
        req.io,
        snap,
        req.worktree_root,
        req.run_id,
        req.candidate_id,
        req.agent_id,
    );
    defer candidate.deinit(allocator);

    try workspace.writeFile(allocator, req.io, candidate.worktree_path, req.file_path, req.replacement);
    try workspace.commitAll(allocator, req.io, &candidate, "openfugu candidate");

    var candidate_verification = try verify.run(allocator, req.io, candidate.worktree_path, req.verify_commands);
    errdefer candidate_verification.deinit(allocator);
    if (!candidate_verification.passed) {
        return .{
            .accepted = false,
            .applied = false,
            .reverified = false,
            .candidate_verification = candidate_verification,
            .final_verification = try verify.run(allocator, req.io, req.repo_path, &.{}),
        };
    }

    try workspace.applyNoCommit(allocator, req.io, snap, candidate);

    var final_verification = try verify.run(allocator, req.io, req.repo_path, req.verify_commands);
    errdefer final_verification.deinit(allocator);

    return .{
        .accepted = final_verification.passed,
        .applied = true,
        .reverified = final_verification.passed,
        .candidate_verification = candidate_verification,
        .final_verification = final_verification,
    };
}
