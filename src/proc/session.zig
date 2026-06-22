pub const State = enum {
    created,
    spawning,
    running,
    draining,
    exited,
    reaped,
    canceling,
    timed_out,
    failed,
};

pub const Session = struct {
    id: []const u8,
    state: State = .created,

    pub fn init(id: []const u8) Session {
        return .{ .id = id };
    }

    pub fn transition(self: *Session, next: State) !void {
        if (!allowed(self.state, next)) return error.InvalidTransition;
        self.state = next;
    }
};

fn allowed(from: State, to: State) bool {
    return switch (from) {
        .created => to == .spawning,
        .spawning => to == .running or to == .failed,
        .running => to == .draining or to == .canceling or to == .timed_out or to == .failed,
        .draining => to == .exited or to == .failed,
        .exited => to == .reaped,
        .canceling => to == .exited or to == .reaped,
        .timed_out => to == .reaped,
        .failed => to == .reaped,
        .reaped => false,
    };
}
