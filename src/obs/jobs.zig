const std = @import("std");

/// Job state for the async submit/poll/wait flow. Each job is a single
/// JSON file under `.openfugu/jobs/<id>.json` so polling is a stateless
/// file read, not a daemon query.
pub const Status = enum {
    queued,
    running,
    ok,
    failed,
    canceled,
};

pub const Job = struct {
    id: []const u8,
    status: Status = .queued,
    task: []const u8 = "",
    agent: []const u8 = "",
    router: []const u8 = "",
    route: []const u8 = "",
    exit_code: ?u8 = null,
    created_ms: u64 = 0,
    started_ms: u64 = 0,
    ended_ms: u64 = 0,
    summary: []const u8 = "",
};

pub const DirName = ".openfugu/jobs";

/// deinitJob frees every owned field of a Job parsed from disk.
/// After this call the Job is undefined and must not be read.
pub fn deinitJob(allocator: std.mem.Allocator, job: *Job) void {
    if (job.id.len != 0) allocator.free(job.id);
    if (job.task.len != 0) allocator.free(job.task);
    if (job.agent.len != 0) allocator.free(job.agent);
    if (job.router.len != 0) allocator.free(job.router);
    if (job.route.len != 0) allocator.free(job.route);
    if (job.summary.len != 0) allocator.free(job.summary);
    job.* = undefined;
}

/// jobsDir returns the allocator-owned path to the jobs directory.
pub fn jobsDir(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, DirName);
}

/// jobPath returns the allocator-owned path to a single job file.
pub fn jobPath(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ DirName, id });
}

/// ensureDir creates `.openfugu/jobs` if missing.
pub fn ensureDir(io: std.Io) !void {
    try std.Io.Dir.cwd().createDirPath(io, DirName);
}

/// write writes (or overwrites) a job file. Owner-only permissions match
/// the ledger policy.
pub fn write(allocator: std.mem.Allocator, io: std.Io, job: Job) !void {
    const text = try format(allocator, job);
    defer allocator.free(text);
    const path = try jobPath(allocator, job.id);
    defer allocator.free(path);
    try ensureDir(io);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = true,
        .permissions = ownerOnlyPermissions(),
    });
    defer file.close(io);
    try file.setPermissions(io, ownerOnlyPermissions());
    try file.writePositionalAll(io, text, 0);
}

/// read loads a job file. Returns null if the file does not exist.
pub fn read(allocator: std.mem.Allocator, io: std.Io, id: []const u8) !?Job {
    const path = try jobPath(allocator, id);
    defer allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(text);
    return try parse(allocator, text);
}

/// listIds returns all job ids found in the jobs directory, newest
/// first (by mtime). Returns an empty slice if the directory is absent.
pub fn listIds(allocator: std.mem.Allocator, io: std.Io) ![][]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, DirName, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]u8, 0),
        else => return err,
    };
    defer dir.close(io);
    var entries = std.ArrayList(Entry).empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }
        entries.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const id = entry.name[0 .. entry.name.len - ".json".len];
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, id),
            .mtime = 0,
        });
    }
    // Sort by name descending as a simple proxy for recency when mtime
    // is unavailable. Good enough for a short jobs dir; callers that
    // need exact order can stat each file.
    std.mem.sort(Entry, entries.items, {}, lessThan);
    var ids = try allocator.alloc([]u8, entries.items.len);
    for (entries.items, 0..) |entry, i| ids[i] = entry.name;
    entries.deinit(allocator);
    return ids;
}

const Entry = struct {
    name: []u8,
    mtime: i128,
};

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .gt;
}

/// format renders a Job as a single-line JSON object. Fields are
/// emitted in a fixed order so diffing is stable.
pub fn format(allocator: std.mem.Allocator, job: Job) ![]u8 {
    const task_escaped = try escapeJson(allocator, job.task);
    defer allocator.free(task_escaped);
    const agent_escaped = try escapeJson(allocator, job.agent);
    defer allocator.free(agent_escaped);
    const router_escaped = try escapeJson(allocator, job.router);
    defer allocator.free(router_escaped);
    const route_escaped = try escapeJson(allocator, job.route);
    defer allocator.free(route_escaped);
    const summary_escaped = try escapeJson(allocator, job.summary);
    defer allocator.free(summary_escaped);
    const exit_code_text: []const u8 = if (job.exit_code) |code|
        std.fmt.allocPrint(allocator, "{d}", .{code}) catch return error.OutOfMemory
    else
        "null";
    const owns_exit = job.exit_code != null;
    defer if (owns_exit) allocator.free(exit_code_text);
    return std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","status":"{s}","task":"{s}","agent":"{s}","router":"{s}","route":"{s}","exit_code":{s},"created_ms":{d},"started_ms":{d},"ended_ms":{d},"summary":"{s}"}}
    , .{
        job.id,
        @tagName(job.status),
        task_escaped,
        agent_escaped,
        router_escaped,
        route_escaped,
        exit_code_text,
        job.created_ms,
        job.started_ms,
        job.ended_ms,
        summary_escaped,
    });
}

/// parse reads a single-line JSON job file back into a Job. The parser
/// is deliberately tolerant: it only looks for the fields we care about
/// and ignores unknown ones, so older job files keep working when new
/// fields are added.
pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !Job {
    var job = Job{ .id = "" };
    job.id = try jsonStringField(allocator, raw, "id") orelse try allocator.dupe(u8, "");
    job.task = try jsonStringField(allocator, raw, "task") orelse try allocator.dupe(u8, "");
    job.agent = try jsonStringField(allocator, raw, "agent") orelse try allocator.dupe(u8, "");
    job.router = try jsonStringField(allocator, raw, "router") orelse try allocator.dupe(u8, "");
    job.route = try jsonStringField(allocator, raw, "route") orelse try allocator.dupe(u8, "");
    job.summary = try jsonStringField(allocator, raw, "summary") orelse try allocator.dupe(u8, "");
    if (try jsonStringField(allocator, raw, "status")) |status_text| {
        defer allocator.free(status_text);
        job.status = statusFromString(status_text) orelse .queued;
    }
    if (jsonU64Field(raw, "exit_code")) |code| job.exit_code = @intCast(code);
    job.created_ms = jsonU64Field(raw, "created_ms") orelse 0;
    job.started_ms = jsonU64Field(raw, "started_ms") orelse 0;
    job.ended_ms = jsonU64Field(raw, "ended_ms") orelse 0;
    return job;
}

fn escapeJson(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |byte| switch (byte) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => if (byte < 0x20) {
            try out.print(allocator, "\\u{x:0>4}", .{byte});
        } else {
            try out.append(allocator, byte);
        },
    };
    return out.toOwnedSlice(allocator);
}

fn jsonStringField(allocator: std.mem.Allocator, raw: []const u8, key: []const u8) !?[]u8 {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\":", .{key});
    defer allocator.free(needle);
    const pos = std.mem.indexOf(u8, raw, needle) orelse return null;
    var i = pos + needle.len;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
    if (i >= raw.len) return null;
    if (raw[i] != '"') return null;
    i += 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (i < raw.len) : (i += 1) {
        const byte = raw[i];
        if (byte == '"') break;
        if (byte == '\\' and i + 1 < raw.len) {
            const next = raw[i + 1];
            switch (next) {
                '"' => try out.append(allocator, '"'),
                '\\' => try out.append(allocator, '\\'),
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                't' => try out.append(allocator, '\t'),
                else => try out.append(allocator, next),
            }
            i += 1;
        } else {
            try out.append(allocator, byte);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn jsonU64Field(raw: []const u8, key: []const u8) ?u64 {
    var needle_buf: [64]u8 = undefined;
    if (key.len + 4 > needle_buf.len) return null;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, raw, needle) orelse return null;
    var i = pos + needle.len;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
    const start = i;
    while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u64, raw[start..i], 10) catch null;
}

fn statusFromString(value: []const u8) ?Status {
    if (std.mem.eql(u8, value, "queued")) return .queued;
    if (std.mem.eql(u8, value, "running")) return .running;
    if (std.mem.eql(u8, value, "ok")) return .ok;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    if (std.mem.eql(u8, value, "canceled")) return .canceled;
    return null;
}

fn ownerOnlyPermissions() std.Io.File.Permissions {
    return if (@hasDecl(std.Io.File.Permissions, "fromMode"))
        std.Io.File.Permissions.fromMode(0o600)
    else
        .default_file;
}
