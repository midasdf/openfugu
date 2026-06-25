const std = @import("std");
const cli = @import("cli.zig");

/// MCP server mode: speaks JSON-RPC 2.0 over stdio and exposes openfugu
/// subcommands as MCP tools so coding agents (opencode, Claude Code,
/// Codex) can call openfugu without spawning the CLI directly.
///
/// The protocol is deliberately minimal: initialize, tools/list, and
/// tools/call. No notifications, no resources, no prompts. The server
/// reads line-delimited JSON-RPC from stdin and writes responses to
/// stdout. This matches how opencode and other MCP clients launch
/// local command-based servers.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    handler: *const fn (allocator: std.mem.Allocator, io: std.Io, params: []const u8) anyerror![]u8,
};

pub const tools = [_]Tool{
    .{
        .name = "route",
        .description = "Inspect the routing decision for a coding task without running any agent. Prints the router name, classified route, preferred agent, per-agent scores (including ledger reputation), and the selected agent. No subscription quota is consumed.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\",\"description\":\"The coding task to route.\"}},\"required\":[\"task\"]}",
        .handler = handleRoute,
    },
    .{
        .name = "run",
        .description = "Route and execute a coding task. Runs the selected agent in an isolated candidate worktree, verifies the result with objective commands, and if verification passes, applies the accepted commit with cherry-pick --no-commit and re-runs verification on the real working tree. Consumes subscription quota.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\",\"description\":\"The coding task to execute.\"},\"planner\":{\"type\":\"string\",\"enum\":[\"heuristic\",\"subscription-agent\",\"capability\"],\"description\":\"Routing planner backend.\"},\"agents\":{\"type\":\"string\",\"description\":\"Restrict to one agent: claude, codex, agy.\"},\"no_apply\":{\"type\":\"boolean\",\"description\":\"Run without applying the candidate patch.\"}},\"required\":[\"task\"]}",
        .handler = handleRun,
    },
    .{
        .name = "submit",
        .description = "Fire a coding task asynchronously and return immediately with a job id. The task runs in a detached child process that updates the job file at completion. Use poll or wait to check the result. No daemon required.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\",\"description\":\"The coding task to submit.\"},\"planner\":{\"type\":\"string\",\"enum\":[\"heuristic\",\"subscription-agent\",\"capability\"]}},\"required\":[\"task\"]}",
        .handler = handleSubmit,
    },
    .{
        .name = "poll",
        .description = "Check the status of a submitted job without blocking. Returns the job's current status, agent, router, route, exit code, and summary.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"job_id\":{\"type\":\"string\",\"description\":\"The job id returned by submit.\"}},\"required\":[\"job_id\"]}",
        .handler = handlePoll,
    },
    .{
        .name = "wait",
        .description = "Block until a submitted job reaches a terminal status (ok, failed, canceled). Exits with the job's exit code when known. Polls the job file on a 500ms interval.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"job_id\":{\"type\":\"string\",\"description\":\"The job id returned by submit.\"}},\"required\":[\"job_id\"]}",
        .handler = handleWait,
    },
    .{
        .name = "doctor",
        .description = "Run setup and dependency diagnostics. Reports config, git, and worktree status plus per-agent compatibility, auth, and runnability. No quota consumed.",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .handler = handleDoctor,
    },
    .{
        .name = "list_agents",
        .description = "List detected agents and their runnability. No quota consumed.",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .handler = handleListAgents,
    },
    .{
        .name = "status",
        .description = "Summary of agents and ledger health. Reports agent count, runnable count, ledger calls, successes, failures, and rate limits. No quota consumed.",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .handler = handleStatus,
    },
};

pub fn run(allocator: std.mem.Allocator, io: std.Io) !u8 {
    // Read line-delimited JSON-RPC from stdin, write responses to stdout.
    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &out_buf);

    while (true) {
        const line = try reader.interface.takeDelimiter('\n') orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const response = handleRequest(allocator, io, trimmed) catch |err| {
            const err_text = std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":-32603,\"message\":\"{s}\"}}}}\n", .{@errorName(err)}) catch return 1;
            defer allocator.free(err_text);
            try writer.interface.writeAll(err_text);
            try writer.interface.flush();
            continue;
        };
        defer allocator.free(response);
        try writer.interface.writeAll(response);
        try writer.interface.writeAll("\n");
        try writer.interface.flush();
    }
    return 0;
}

fn handleRequest(allocator: std.mem.Allocator, io: std.Io, raw: []const u8) ![]u8 {
    const method = jsonStringFieldTemp(raw, "\"method\"") orelse return error.MissingMethod;
    defer freeTemp(method);
    const id = jsonIdFieldTemp(raw);

    if (std.mem.eql(u8, method, "initialize")) {
        return initializeResponse(allocator, id);
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        // Notification: no response per spec.
        return allocator.dupe(u8, "");
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return toolsListResponse(allocator, id);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return toolsCallResponse(allocator, io, raw, id);
    }
    return methodNotFound(allocator, id, method);
}

fn initializeResponse(allocator: std.mem.Allocator, id: IdValue) ![]u8 {
    const id_text = try idText(allocator, id);
    defer allocator.free(id_text);
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{s},"result":{{"protocolVersion":"2024-11-05","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"openfugu","version":"0.2.0"}}}}}}
    , .{id_text});
}

fn toolsListResponse(allocator: std.mem.Allocator, id: IdValue) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const id_text = try idText(allocator, id);
    defer allocator.free(id_text);
    try out.print(allocator,
        \\{{"jsonrpc":"2.0","id":{s},"result":{{"tools":[
    , .{id_text});
    for (tools, 0..) |tool, i| {
        if (i != 0) try out.append(allocator, ',');
        try out.print(allocator,
            \\{{"name":"{s}","description":"{s}","inputSchema":{s}}}
        , .{ tool.name, tool.description, tool.input_schema });
    }
    try out.appendSlice(allocator, "]}}");
    return out.toOwnedSlice(allocator);
}

fn toolsCallResponse(allocator: std.mem.Allocator, io: std.Io, raw: []const u8, id: IdValue) ![]u8 {
    // The params object contains "name" (string) and "arguments"
    // (object). We extract name and arguments directly from the raw
    // text because our minimal JSON helpers only handle string fields.
    const name = jsonStringFieldTemp(raw, "\"name\"") orelse return error.MissingToolName;
    // Arguments may be absent or an empty object; we pass the raw
    // arguments text to the handler.
    const arguments = jsonObjectFieldTemp(raw, "\"arguments\"") orelse "";

    // Find the tool.
    var handler: *const fn (std.mem.Allocator, std.Io, []const u8) anyerror![]u8 = undefined;
    var found = false;
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) {
            handler = tool.handler;
            found = true;
            break;
        }
    }
    if (!found) {
        const id_text = try idText(allocator, id);
        defer allocator.free(id_text);
        return std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":{s},"error":{{"code":-32601,"message":"unknown tool: {s}"}}}}
        , .{ id_text, name });
    }

    const result_text = try handler(allocator, io, arguments);
    defer allocator.free(result_text);
    const escaped = try escapeJsonString(allocator, result_text);
    defer allocator.free(escaped);
    const id_text = try idText(allocator, id);
    defer allocator.free(id_text);
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"{s}"}}]}}}}
    , .{ id_text, escaped });
}

fn methodNotFound(allocator: std.mem.Allocator, id: IdValue, method: []const u8) ![]u8 {
    const id_text = try idText(allocator, id);
    defer allocator.free(id_text);
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{s},"error":{{"code":-32601,"message":"method not found: {s}"}}}}
    , .{ id_text, method });
}

// --- Tool handlers ---

fn handleRoute(allocator: std.mem.Allocator, io: std.Io, params: []const u8) ![]u8 {
    const task = jsonStringFieldTemp(params, "\"task\"") orelse return error.MissingTaskArg;
    defer freeTemp(task);
    return cliResult(allocator, io, &.{ "openfugu", "route", task });
}

fn handleRun(allocator: std.mem.Allocator, io: std.Io, params: []const u8) ![]u8 {
    const task = jsonStringFieldTemp(params, "\"task\"") orelse return error.MissingTaskArg;
    defer freeTemp(task);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "openfugu");
    try args.append(allocator, "run");
    if (jsonStringFieldTemp(params, "\"planner\"")) |planner| {
        const flag = try std.fmt.allocPrint(allocator, "--planner={s}", .{planner});
        defer allocator.free(flag);
        try args.append(allocator, flag);
    }
    if (jsonStringFieldTemp(params, "\"agents\"")) |agent| {
        const flag = try std.fmt.allocPrint(allocator, "--agents={s}", .{agent});
        defer allocator.free(flag);
        try args.append(allocator, flag);
    }
    if (jsonBoolField(params, "\"no_apply\"")) |no_apply| {
        if (no_apply) try args.append(allocator, "--no-apply");
    }
    try args.append(allocator, task);
    return cliResult(allocator, io, args.items);
}

fn handleSubmit(allocator: std.mem.Allocator, io: std.Io, params: []const u8) ![]u8 {
    const task = jsonStringFieldTemp(params, "\"task\"") orelse return error.MissingTaskArg;
    defer freeTemp(task);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "openfugu");
    try args.append(allocator, "submit");
    if (jsonStringFieldTemp(params, "\"planner\"")) |planner| {
        const flag = try std.fmt.allocPrint(allocator, "--planner={s}", .{planner});
        defer allocator.free(flag);
        try args.append(allocator, flag);
    }
    try args.append(allocator, task);
    return cliResult(allocator, io, args.items);
}

fn handlePoll(allocator: std.mem.Allocator, io: std.Io, params: []const u8) ![]u8 {
    const job_id = jsonStringFieldTemp(params, "\"job_id\"") orelse return error.MissingJobIdArg;
    defer freeTemp(job_id);
    return cliResult(allocator, io, &.{ "openfugu", "poll", job_id });
}

fn handleWait(allocator: std.mem.Allocator, io: std.Io, params: []const u8) ![]u8 {
    const job_id = jsonStringFieldTemp(params, "\"job_id\"") orelse return error.MissingJobIdArg;
    defer freeTemp(job_id);
    return cliResult(allocator, io, &.{ "openfugu", "wait", job_id });
}

fn handleDoctor(allocator: std.mem.Allocator, io: std.Io, _: []const u8) ![]u8 {
    return cliResult(allocator, io, &.{ "openfugu", "doctor" });
}

fn handleListAgents(allocator: std.mem.Allocator, io: std.Io, _: []const u8) ![]u8 {
    return cliResult(allocator, io, &.{ "openfugu", "list-agents" });
}

fn handleStatus(allocator: std.mem.Allocator, io: std.Io, _: []const u8) ![]u8 {
    return cliResult(allocator, io, &.{ "openfugu", "status" });
}

/// cliResult invokes openfugu.cli.runWithIo with the given argv and
/// returns the result text. This reuses the exact same code path as
/// the CLI so MCP tool calls and CLI calls behave identically.
fn cliResult(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]u8 {
    var result = openfugu_cli_runWithIo(allocator, io, args) catch |err| {
        return std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)});
    };
    defer result.deinit(allocator);
    return allocator.dupe(u8, result.text);
}

// --- JSON helpers (temporary, borrowed slice into raw) ---

const IdValue = union(enum) {
    none,
    number: i64,
    text: []const u8,
};

fn jsonIdFieldTemp(raw: []const u8) IdValue {
    const needle = "\"id\":";
    const pos = std.mem.indexOf(u8, raw, needle) orelse return .none;
    var i = pos + needle.len;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
    if (i >= raw.len) return .none;
    if (raw[i] == '"') {
        const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '"') orelse return .none;
        return .{ .text = raw[i + 1 .. end] };
    }
    const start = i;
    while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') i += 1;
    if (i == start) return .none;
    const num = std.fmt.parseInt(i64, raw[start..i], 10) catch return .none;
    return .{ .number = num };
}

fn idText(allocator: std.mem.Allocator, id: IdValue) ![]const u8 {
    return switch (id) {
        .none => allocator.dupe(u8, "null"),
        .number => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .text => |t| std.fmt.allocPrint(allocator, "\"{s}\"", .{t}),
    };
}

fn jsonStringFieldTemp(raw: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, raw, key) orelse return null;
    var i = pos + key.len;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == ':')) i += 1;
    if (i >= raw.len) return null;
    if (raw[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            continue;
        }
        if (raw[i] == '"') return raw[start..i];
    }
    return null;
}

fn freeTemp(_: []const u8) void {
    // No-op: jsonStringFieldTemp returns borrowed slices.
}

/// jsonObjectFieldTemp returns the raw text of a JSON object value
/// associated with key. It finds the key, skips to the opening brace,
/// and tracks brace depth to find the matching close. Returns null if
/// the key is absent or the value is not an object.
fn jsonObjectFieldTemp(raw: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, raw, key) orelse return null;
    var i = pos + key.len;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == ':')) i += 1;
    if (i >= raw.len or raw[i] != '{') return null;
    const start = i;
    var depth: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '{') {
            depth += 1;
        } else if (raw[i] == '}') {
            depth -= 1;
            if (depth == 0) return raw[start .. i + 1];
        } else if (raw[i] == '"') {
            // Skip string contents to avoid counting braces inside them.
            i += 1;
            while (i < raw.len) : (i += 1) {
                if (raw[i] == '\\' and i + 1 < raw.len) {
                    i += 1;
                    continue;
                }
                if (raw[i] == '"') break;
            }
        }
    }
    return null;
}

fn jsonBoolField(raw: []const u8, key: []const u8) ?bool {
    const needle_prefix = key;
    const pos = std.mem.indexOf(u8, raw, needle_prefix) orelse return null;
    var i = pos + needle_prefix.len;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == ':')) i += 1;
    if (std.mem.startsWith(u8, raw[i..], "true")) return true;
    if (std.mem.startsWith(u8, raw[i..], "false")) return false;
    return null;
}

fn escapeJsonString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
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

// Forward declaration: cli.runWithIo is the same entry point the CLI
// uses, so MCP tool calls and CLI calls behave identically.
fn openfugu_cli_runWithIo(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !cli.Result {
    return cli.runWithIo(allocator, io, args);
}
