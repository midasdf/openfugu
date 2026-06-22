const std = @import("std");

pub fn filterKeys(
    allocator: std.mem.Allocator,
    keys: []const []const u8,
    denied: []const []const u8,
) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    errdefer kept.deinit(allocator);

    for (keys) |key| {
        if (!contains(denied, key)) {
            try kept.append(allocator, key);
        }
    }

    return kept.toOwnedSlice(allocator);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}
