const std = @import("std");

pub const EventKind = enum {
    status,
    assistant_text,
    tool_call,
    file_change,
    usage,
    quota,
    rate_limit,
    diagnostic,
    final,
};

pub const Event = struct {
    kind: EventKind,
    text: []const u8,
};

pub fn cloneEvents(allocator: std.mem.Allocator, events: []const Event) ![]Event {
    const out = try allocator.alloc(Event, events.len);
    for (events, 0..) |event, i| out[i] = .{
        .kind = event.kind,
        .text = try allocator.dupe(u8, event.text),
    };
    return out;
}

pub fn freeEvents(allocator: std.mem.Allocator, events: []Event) void {
    for (events) |event| allocator.free(event.text);
    allocator.free(events);
}
