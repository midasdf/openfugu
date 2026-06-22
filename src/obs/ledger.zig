const std = @import("std");
const config = @import("../config.zig");

pub const Event = struct {
    run_id: []const u8,
    agent: []const u8,
    content: []const u8,
    include_content: bool = false,
};

pub fn format(allocator: std.mem.Allocator, event: Event) ![]u8 {
    if (event.include_content) {
        const redacted = try config.redactKnownSecrets(allocator, event.content);
        defer allocator.free(redacted);
        return std.fmt.allocPrint(allocator, "{{\"schema\":1,\"run\":\"{s}\",\"agent\":\"{s}\",\"content\":\"{s}\"}}\n", .{ event.run_id, event.agent, redacted });
    }
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(event.content);
    return std.fmt.allocPrint(allocator, "{{\"schema\":1,\"run\":\"{s}\",\"agent\":\"{s}\",\"content_hash\":\"{x}\"}}\n", .{ event.run_id, event.agent, hasher.final() });
}

pub fn append(allocator: std.mem.Allocator, io: std.Io, path: []const u8, event: Event) !void {
    const line = try format(allocator, event);
    defer allocator.free(line);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .permissions = ownerOnlyPermissions(),
    });
    defer file.close(io);
    try file.setPermissions(io, ownerOnlyPermissions());

    const stat = try file.stat(io);
    try file.writePositionalAll(io, line, stat.size);
}

fn ownerOnlyPermissions() std.Io.File.Permissions {
    return if (@hasDecl(std.Io.File.Permissions, "fromMode"))
        std.Io.File.Permissions.fromMode(0o600)
    else
        .default_file;
}
