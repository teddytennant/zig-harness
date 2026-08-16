const std = @import("std");
const json = @import("../json.zig");
const util = @import("../util.zig");
const tools = @import("mod.zig");
const c = @cImport({
    @cInclude("curl/curl.h");
});

pub fn register(registry: *tools.Registry) !void {
    try registry.register(.{
        .name = "web_fetch",
        .description = "Fetch a URL over HTTP(S) and return its content. HTML pages are converted to markdown; other text content is returned as-is. Responses are size-capped.",
        .parameters_json =
            \\{"type":"object","properties":{"url":{"type":"string","description":"The http(s) URL to fetch"},"max_bytes":{"type":"integer","description":"Cap on response bytes read (default 200000)"}},"required":["url"]}
        ,
        .access = .read_only,
        .run = webFetch,
    });
    try registry.register(.{
        .name = "web_search",
        .description = "Search the web and return a numbered list of results (title, url, snippet).",
        .parameters_json =
            \\{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"count":{"type":"integer","description":"Number of results (default 5, max 10)"}},"required":["query"]}
        ,
        .access = .read_only,
        .run = webSearch,
    });
}

const WriterCtx = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cap: usize,
};

fn writeCb(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const ctx: *WriterCtx = @ptrCast(@alignCast(userdata.?));
    const n = size * nmemb;
    const room = if (ctx.list.items.len >= ctx.cap) 0 else ctx.cap - ctx.list.items.len;
    const take = @min(n, room);
    ctx.list.appendSlice(ctx.allocator, ptr[0..take]) catch return 0;
    return n; // pretend we ate it all so curl does not error; we just stop growing
}

fn fetchUrl(allocator: std.mem.Allocator, url: []const u8, cap: usize) ![]u8 {
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != 0) return error.CurlInit;
    defer c.curl_global_cleanup();

    const easy = c.curl_easy_init() orelse return error.CurlInit;
    defer c.curl_easy_cleanup(easy);

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    var wctx = WriterCtx{ .list = &body, .allocator = allocator, .cap = cap };

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);

    _ = c.curl_easy_setopt(easy, c.CURLOPT_URL, url_z.ptr);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_USERAGENT, "zig-harness/0.1");
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, writeCb);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, &wctx);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_TIMEOUT, @as(c_long, 30));

    const rc = c.curl_easy_perform(easy);
    if (rc != c.CURLE_OK) {
        body.deinit(allocator);
        return error.CurlPerform;
    }
    return body.toOwnedSlice(allocator);
}

fn looksHtml(text: []const u8) bool {
    const head = if (text.len > 256) text[0..256] else text;
    var lower: [256]u8 = undefined;
    const n = head.len;
    for (head, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
    return std.mem.indexOf(u8, lower[0..n], "<html") != null or
        std.mem.indexOf(u8, lower[0..n], "<!doctype") != null;
}

fn htmlToText(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var skip: bool = false;
    while (i < html.len) {
        if (html[i] == '<') {
            if (i + 6 < html.len and std.ascii.eqlIgnoreCase(html[i .. i + 6], "<script")) skip = true;
            if (i + 6 < html.len and std.ascii.eqlIgnoreCase(html[i .. i + 6], "<style")) skip = true;
            if (i + 8 < html.len and std.ascii.eqlIgnoreCase(html[i .. i + 8], "</script")) skip = false;
            if (i + 7 < html.len and std.ascii.eqlIgnoreCase(html[i .. i + 7], "</style")) skip = false;
            if (i + 2 < html.len and (html[i + 1] == 'p' or html[i + 1] == 'P' or
                std.mem.startsWith(u8, html[i..], "<br") or
                std.mem.startsWith(u8, html[i..], "<BR") or
                std.mem.startsWith(u8, html[i..], "<h") or
                std.mem.startsWith(u8, html[i..], "<H") or
                std.mem.startsWith(u8, html[i..], "<li") or
                std.mem.startsWith(u8, html[i..], "<LI")))
            {
                try out.append(allocator, '\n');
            }
            while (i < html.len and html[i] != '>') i += 1;
            if (i < html.len) i += 1;
            continue;
        }
        if (!skip) {
            if (html[i] == '&') {
                if (std.mem.startsWith(u8, html[i..], "&amp;")) {
                    try out.append(allocator, '&');
                    i += 5;
                    continue;
                }
                if (std.mem.startsWith(u8, html[i..], "&lt;")) {
                    try out.append(allocator, '<');
                    i += 4;
                    continue;
                }
                if (std.mem.startsWith(u8, html[i..], "&gt;")) {
                    try out.append(allocator, '>');
                    i += 4;
                    continue;
                }
                if (std.mem.startsWith(u8, html[i..], "&nbsp;")) {
                    try out.append(allocator, ' ');
                    i += 6;
                    continue;
                }
            }
            try out.append(allocator, html[i]);
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn webFetch(ctx: *tools.Context, args: json.Value) !tools.Output {
    const url = json.getString(args, "url") orelse return tools.Output.err("url is required");
    if (!(std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://"))) {
        return tools.Output.err("url must be http(s)");
    }
    var cap = json.getUsize(args, "max_bytes") orelse 200_000;
    if (cap == 0) cap = 1;
    if (cap > 1_000_000) cap = 1_000_000;

    const body = fetchUrl(ctx.allocator, url, cap) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "fetch failed: {s}", .{@errorName(err)});
        return tools.Output.errOwned(msg);
    };
    defer ctx.allocator.free(body);

    if (looksHtml(body)) {
        const text = try htmlToText(ctx.allocator, body);
        defer ctx.allocator.free(text);
        return tools.Output.okOwned(try util.truncate(ctx.allocator, text, util.max_output_bytes));
    }
    return tools.Output.okOwned(try util.truncate(ctx.allocator, body, util.max_output_bytes));
}

fn webSearch(ctx: *tools.Context, args: json.Value) !tools.Output {
    const query = json.getString(args, "query") orelse return tools.Output.err("query must not be empty");
    if (std.mem.trim(u8, query, " \t\n").len == 0) return tools.Output.err("query must not be empty");
    var count = json.getUsize(args, "count") orelse 5;
    if (count == 0) count = 1;
    if (count > 10) count = 10;

    // DuckDuckGo HTML, no API key. Fragile but dependency-free.
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(ctx.allocator);
    for (query) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') {
            try encoded.append(ctx.allocator, ch);
        } else if (ch == ' ') {
            try encoded.append(ctx.allocator, '+');
        } else {
            try encoded.writer(ctx.allocator).print("%{X:0>2}", .{ch});
        }
    }
    const url = try std.fmt.allocPrint(ctx.allocator, "https://html.duckduckgo.com/html/?q={s}", .{encoded.items});
    defer ctx.allocator.free(url);

    const body = fetchUrl(ctx.allocator, url, 400_000) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "search failed: {s}", .{@errorName(err)});
        return tools.Output.errOwned(msg);
    };
    defer ctx.allocator.free(body);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    var found: usize = 0;
    var i: usize = 0;
    while (i < body.len and found < count) {
        const needle = "uddg=";
        const at = std.mem.indexOfPos(u8, body, i, needle) orelse break;
        const j = at + needle.len;
        const end = std.mem.indexOfPos(u8, body, j, "&") orelse std.mem.indexOfPos(u8, body, j, "\"") orelse break;
        const raw = body[j..end];
        const decoded = urlDecode(ctx.allocator, raw) catch {
            i = end;
            continue;
        };
        defer ctx.allocator.free(decoded);
        found += 1;
        try out.writer(ctx.allocator).print("{d}. {s}\n", .{ found, decoded });
        i = end;
    }
    if (found == 0) return tools.Output.ok("(no results)");
    return tools.Output.okOwned(try out.toOwnedSlice(ctx.allocator));
}

fn urlDecode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const n = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, s[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, n);
            i += 3;
        } else if (s[i] == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}
