pub const Event = struct {
    agent: []const u8,
    reported_tokens: ?u64,
    rate_limited: bool,
    ok: bool,
};

pub const Summary = struct {
    calls: u64 = 0,
    reported_tokens: u64 = 0,
    unavailable_tokens: u64 = 0,
    rate_limits: u64 = 0,
    successes: u64 = 0,
    failures: u64 = 0,
};

pub fn summarize(events: []const Event) Summary {
    var out: Summary = .{};
    for (events) |event| {
        out.calls += 1;
        if (event.reported_tokens) |tokens| {
            out.reported_tokens += tokens;
        } else {
            out.unavailable_tokens += 1;
        }
        if (event.rate_limited) out.rate_limits += 1;
        if (event.ok) out.successes += 1 else out.failures += 1;
    }
    return out;
}
