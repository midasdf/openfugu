pub const Budget = struct {
    max_depth: u32,
    remaining_agent_calls: u32,

    pub fn consumeReplan(self: *Budget) bool {
        if (self.max_depth == 0 or self.remaining_agent_calls == 0) return false;
        self.max_depth -= 1;
        self.remaining_agent_calls -= 1;
        return true;
    }
};
