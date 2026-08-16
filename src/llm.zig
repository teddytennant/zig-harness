//! OpenAI-compatible Chat Completions client (non-streaming).

const std = @import("std");
const json = @import("json.zig");
const config = @import("config.zig");
const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const Role = enum { system, user, assistant, tool };

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls: []ToolCall = &.{},
};

pub const Response = struct {
    content: []const u8,
    tool_calls: []ToolCall,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Response) void {
        self.arena.deinit();
    }
};

const Body = struct {
    list: std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

fn writeCb(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const body: *Body = @ptrCast(@alignCast(userdata.?));
    const n = size * nmemb;
    body.list.appendSlice(body.allocator, ptr[0..n]) catch return 0;
    return n;
}

fn httpPost(allocator: std.mem.Allocator, url: []const u8, bearer: ?[]const u8, payload: []const u8) ![]u8 {
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != 0) return error.CurlInit;
    defer c.curl_global_cleanup();
    const easy = c.curl_easy_init() orelse return error.CurlInit;
    defer c.curl_easy_cleanup(easy);

    var body = Body{ .list = .empty, .allocator = allocator };
    errdefer body.list.deinit(allocator);

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    const payload_z = try allocator.dupeZ(u8, payload);
    defer allocator.free(payload_z);

    var headers: ?*c.curl_slist = null;
    headers = c.curl_slist_append(headers, "Content-Type: application/json");
    if (bearer) |tok| {
        const hdr = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{tok});
        defer allocator.free(hdr);
        const hdr_z = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_z);
        headers = c.curl_slist_append(headers, hdr_z.ptr);
    }
    defer c.curl_slist_free_all(headers);

    _ = c.curl_easy_setopt(easy, c.CURLOPT_URL, url_z.ptr);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_HTTPHEADER, headers);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_POST, @as(c_long, 1));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDS, payload_z.ptr);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(payload.len)));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, writeCb);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, &body);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_TIMEOUT, @as(c_long, 120));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_USERAGENT, "zig-harness/0.1");

    const rc = c.curl_easy_perform(easy);
    if (rc != c.CURLE_OK) {
        body.list.deinit(allocator);
        return error.CurlPerform;
    }
    var status: c_long = 0;
    _ = c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status);
    if (status < 200 or status >= 300) {
        const msg = try body.list.toOwnedSlice(allocator);
        defer allocator.free(msg);
        std.debug.print("llm http {d}: {s}\n", .{ status, msg });
        return error.HttpStatus;
    }
    return body.list.toOwnedSlice(allocator);
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, s, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

fn roleName(role: Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

pub fn chat(
    allocator: std.mem.Allocator,
    provider: config.Provider,
    messages: []const Message,
    tools_json: []const u8,
) !Response {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.appendSlice(allocator, "{\"model\":");
    try appendJsonString(&payload, allocator, provider.model);
    try payload.appendSlice(allocator, ",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i != 0) try payload.appendSlice(allocator, ",");
        try payload.appendSlice(allocator, "{\"role\":");
        try appendJsonString(&payload, allocator, roleName(m.role));
        try payload.appendSlice(allocator, ",\"content\":");
        try appendJsonString(&payload, allocator, m.content);
        if (m.role == .tool) {
            if (m.tool_call_id) |id| {
                try payload.appendSlice(allocator, ",\"tool_call_id\":");
                try appendJsonString(&payload, allocator, id);
            }
        }
        if (m.role == .assistant and m.tool_calls.len > 0) {
            try payload.appendSlice(allocator, ",\"tool_calls\":[");
            for (m.tool_calls, 0..) |tc, j| {
                if (j != 0) try payload.appendSlice(allocator, ",");
                try payload.appendSlice(allocator, "{\"id\":");
                try appendJsonString(&payload, allocator, tc.id);
                try payload.appendSlice(allocator, ",\"type\":\"function\",\"function\":{\"name\":");
                try appendJsonString(&payload, allocator, tc.name);
                try payload.appendSlice(allocator, ",\"arguments\":");
                try appendJsonString(&payload, allocator, tc.arguments);
                try payload.appendSlice(allocator, "}}");
            }
            try payload.appendSlice(allocator, "]");
        }
        try payload.appendSlice(allocator, "}");
    }
    try payload.appendSlice(allocator, "]");
    if (tools_json.len > 2) {
        try payload.appendSlice(allocator, ",\"tools\":");
        try payload.appendSlice(allocator, tools_json);
    }
    try payload.appendSlice(allocator, "}");

    const key = if (std.posix.getenv(provider.api_key_env)) |k|
        if (k.len == 0) null else k
    else
        null;

    const base = std.mem.trimRight(u8, provider.base_url, "/");
    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base});
    defer allocator.free(url);

    const raw = try httpPost(allocator, url, key, payload.items);
    defer allocator.free(raw);

    const parsed = json.parse(allocator, raw) catch return error.BadJson;
    defer parsed.deinit();

    const a = arena.allocator();
    var content: []const u8 = "";
    var calls: std.ArrayList(ToolCall) = .empty;

    const choices = json.objectGet(parsed.value, "choices") orelse return error.BadResponse;
    if (choices != .array or choices.array.items.len == 0) return error.BadResponse;
    const msg = json.objectGet(choices.array.items[0], "message") orelse return error.BadResponse;
    if (json.getString(msg, "content")) |s| {
        content = try a.dupe(u8, s);
    }
    if (json.objectGet(msg, "tool_calls")) |tcs| {
        if (tcs == .array) {
            for (tcs.array.items) |tc| {
                const id = json.getString(tc, "id") orelse "call";
                const fnv = json.objectGet(tc, "function") orelse continue;
                const name = json.getString(fnv, "name") orelse continue;
                const arguments = json.getString(fnv, "arguments") orelse "{}";
                try calls.append(a, .{
                    .id = try a.dupe(u8, id),
                    .name = try a.dupe(u8, name),
                    .arguments = try a.dupe(u8, arguments),
                });
            }
        }
    }

    return .{
        .content = content,
        .tool_calls = try calls.toOwnedSlice(a),
        .arena = arena,
    };
}
