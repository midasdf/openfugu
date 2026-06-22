const std = @import("std");
const types = @import("../core/types.zig");

pub const NodeOutput = struct {
    id: types.NodeId,
    text: []const u8,
};

pub const BuildRequest = struct {
    original_request: []const u8,
    outputs: []const NodeOutput,
    access: []const types.ContextRef,
    max_bytes: usize,
};

pub const BuiltContext = struct {
    text: []u8,
    truncated: bool,

    pub fn deinit(self: BuiltContext, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub fn build(allocator: std.mem.Allocator, req: BuildRequest) !BuiltContext {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (req.access) |access| switch (access) {
        .original_request => {
            try out.appendSlice(allocator, "original:\n");
            try out.appendSlice(allocator, req.original_request);
            try out.append(allocator, '\n');
        },
        .node_output => |id| if (findOutput(req.outputs, id)) |text| {
            try out.appendSlice(allocator, "node output:\n");
            try out.appendSlice(allocator, text);
            try out.append(allocator, '\n');
        },
        else => {},
    };

    var text = try out.toOwnedSlice(allocator);
    var truncated = false;
    if (text.len > req.max_bytes) {
        const kept = try allocator.dupe(u8, text[0..req.max_bytes]);
        allocator.free(text);
        text = kept;
        truncated = true;
    }

    return .{ .text = text, .truncated = truncated };
}

fn findOutput(outputs: []const NodeOutput, id: types.NodeId) ?[]const u8 {
    for (outputs) |output| {
        if (output.id == id) return output.text;
    }
    return null;
}
