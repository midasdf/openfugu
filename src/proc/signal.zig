pub const CancelStrategy = struct {
    term_grace_ms: u64 = 1000,
    kill_after_grace: bool = true,
};
