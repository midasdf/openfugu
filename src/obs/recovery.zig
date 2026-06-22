pub const State = struct {
    processes: u32,
    worktrees: u32,
    branches: u32,
    locks: u32,
};

pub const Result = struct {
    clean: bool,
};

pub fn audit(state: State) Result {
    return .{ .clean = state.processes == 0 and state.worktrees == 0 and state.branches == 0 and state.locks == 0 };
}
