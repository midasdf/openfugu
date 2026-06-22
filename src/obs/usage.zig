const std = @import("std");

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

pub fn summarizeLedgerText(text: []const u8) Summary {
    var out: Summary = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        out.calls += 1;
        out.unavailable_tokens += 1;
        if (std.mem.indexOf(u8, line, "\"accepted\":true") != null) {
            out.successes += 1;
        } else {
            out.failures += 1;
        }
        if (std.mem.indexOf(u8, line, "\"rate_limit\":true") != null) out.rate_limits += 1;
    }
    return out;
}
