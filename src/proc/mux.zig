const std = @import("std");
const runner = @import("runner.zig");

pub fn runAll(allocator: std.mem.Allocator, io: std.Io, specs: []const runner.RunSpec) ![]runner.RunResult {
    const results = try allocator.alloc(runner.RunResult, specs.len);
    errdefer allocator.free(results);

    var filled: usize = 0;
    errdefer {
        for (results[0..filled]) |*result| result.deinit(allocator);
    }

    for (specs, 0..) |spec, i| {
        results[i] = try runner.run(allocator, io, spec);
        filled += 1;
    }

    return results;
}

pub fn freeResults(allocator: std.mem.Allocator, results: []runner.RunResult) void {
    for (results) |*result| result.deinit(allocator);
    allocator.free(results);
}
