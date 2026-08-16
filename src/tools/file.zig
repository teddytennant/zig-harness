const std = @import("std");
const json = @import("../json.zig");
const util = @import("../util.zig");
const tools = @import("mod.zig");

pub fn register(registry: *tools.Registry) !void {
    try registry.register(.{
        .name = "read_file",
        .description = "Read the contents of a file, optionally limited to a 1-based line range.",
        .parameters_json =
            \\{"type":"object","properties":{"path":{"type":"string","description":"File path (relative to project root or absolute)"},"start_line":{"type":"integer","description":"1-based first line to include"},"end_line":{"type":"integer","description":"1-based last line to include"}},"required":["path"]}
        ,
        .access = .read_only,
        .run = readFile,
    });
    try registry.register(.{
        .name = "write_file",
        .description =
            \\Create or overwrite a file with the given content, creating parent directories as needed.
            \\
            \\Tips:
            \\- Use for new files or full rewrites; prefer `edit_file` for surgical changes.
            \\- Write required deliverables as soon as you know the path and a schema-valid payload.
        ,
        .parameters_json =
            \\{"type":"object","properties":{"path":{"type":"string","description":"File path to create or overwrite"},"content":{"type":"string","description":"Full file contents"}},"required":["path","content"]}
        ,
        .access = .edit,
        .run = writeFile,
    });
    try registry.register(.{
        .name = "edit_file",
        .description = "Edit a file by exact search-and-replace. old_string must match exactly once unless replace_all is true.",
        .parameters_json =
            \\{"type":"object","properties":{"path":{"type":"string","description":"File to edit"},"old_string":{"type":"string","description":"Exact text to replace"},"new_string":{"type":"string","description":"Replacement text"},"replace_all":{"type":"boolean","description":"Replace all occurrences (default false)"}},"required":["path","old_string","new_string"]}
        ,
        .access = .edit,
        .run = editFile,
    });
    try registry.register(.{
        .name = "list_files",
        .description = "List files and directories under a path, optionally filtered by a glob pattern. Respects .gitignore.",
        .parameters_json =
            \\{"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default: project root)"},"glob":{"type":"string","description":"Glob filter, e.g. **/*.zig"}}}
        ,
        .access = .read_only,
        .run = listFiles,
    });
    try registry.register(.{
        .name = "search_files",
        .description = "Search file contents for a regex pattern (ripgrep if available, grep otherwise). Returns matching lines with file and line number.",
        .parameters_json =
            \\{"type":"object","properties":{"pattern":{"type":"string","description":"Regex pattern"},"path":{"type":"string","description":"Directory to search (default: project root)"},"glob":{"type":"string","description":"Restrict to files matching this glob, e.g. *.zig"}},"required":["pattern"]}
        ,
        .access = .read_only,
        .run = searchFiles,
    });
}

fn readFile(ctx: *tools.Context, args: json.Value) !tools.Output {
    const path_arg = json.getString(args, "path") orelse return tools.Output.err("path is required");
    const start = json.getUsize(args, "start_line");
    const end = json.getUsize(args, "end_line");
    if (start == 0 or end == 0) return tools.Output.err("start_line and end_line are 1-based; 0 is not a valid line");
    if (start != null and end != null and end.? < start.?) {
        return tools.Output.err("end_line is before start_line");
    }

    const path = try util.resolvePath(ctx.allocator, ctx.cwd, path_arg);
    defer ctx.allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "failed to read {s}: {s}", .{ path, @errorName(err) });
        return tools.Output.errOwned(msg);
    };
    defer file.close();

    const content = file.readToEndAlloc(ctx.allocator, 8 * 1024 * 1024) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "failed to read {s}: {s}", .{ path, @errorName(err) });
        return tools.Output.errOwned(msg);
    };
    defer ctx.allocator.free(content);

    if (content.len == 0) return tools.Output.ok("(empty file)");

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(ctx.allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| try lines.append(ctx.allocator, line);
    // drop trailing empty line produced by a final newline
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0 and
        content.len > 0 and content[content.len - 1] == '\n')
    {
        _ = lines.pop();
    }
    const total = lines.items.len;
    if (total == 0) return tools.Output.ok("(empty file)");

    const start_i = start orelse 1;
    if (start_i > total) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "start_line {d} is past the end of {s} ({d} lines)", .{ start_i, path, total });
        return tools.Output.errOwned(msg);
    }
    var end_i = end orelse total;
    if (end_i > total) end_i = total;

    var shown = lines.items[start_i - 1 .. end_i];
    var capped = false;
    if (shown.len > util.max_read_lines) {
        shown = shown[0..util.max_read_lines];
        capped = true;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    for (shown, 0..) |line, offset| {
        if (offset != 0) try out.append(ctx.allocator, '\n');
        try out.writer(ctx.allocator).print("{d: >6}\t{s}", .{ start_i + offset, line });
    }
    if (capped) {
        try out.writer(ctx.allocator).print(
            "\n... [showing {d} of {d} requested lines; total {d} lines — use start_line/end_line to read more]",
            .{ util.max_read_lines, end_i - start_i + 1, total },
        );
    }
    const raw = try out.toOwnedSlice(ctx.allocator);
    const truncated = try util.truncate(ctx.allocator, raw, util.max_output_bytes);
    ctx.allocator.free(raw);
    return tools.Output.okOwned(truncated);
}

fn writeFile(ctx: *tools.Context, args: json.Value) !tools.Output {
    const path_arg = json.getString(args, "path") orelse return tools.Output.err("path is required");
    const content = json.getString(args, "content") orelse return tools.Output.err("content is required");
    const path = try util.resolvePath(ctx.allocator, ctx.cwd, path_arg);
    defer ctx.allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            const msg = try std.fmt.allocPrint(ctx.allocator, "failed to create parent directory {s}: {s}", .{ dir, @errorName(err) });
            return tools.Output.errOwned(msg);
        };
    }

    const existed = blk: {
        std.fs.accessAbsolute(path, .{}) catch break :blk false;
        break :blk true;
    };
    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "failed to write {s}: {s}", .{ path, @errorName(err) });
        return tools.Output.errOwned(msg);
    };
    defer file.close();
    file.writeAll(content) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "failed to write {s}: {s}", .{ path, @errorName(err) });
        return tools.Output.errOwned(msg);
    };
    const verb = if (existed) "Overwrote" else "Created";
    const msg = try std.fmt.allocPrint(ctx.allocator, "{s} {s} ({d} bytes)", .{ verb, path, content.len });
    return tools.Output.okOwned(msg);
}

fn editFile(ctx: *tools.Context, args: json.Value) !tools.Output {
    const path_arg = json.getString(args, "path") orelse return tools.Output.err("path is required");
    const old = json.getString(args, "old_string") orelse return tools.Output.err("old_string is required");
    const new = json.getString(args, "new_string") orelse return tools.Output.err("new_string is required");
    const replace_all = json.getBool(args, "replace_all") orelse false;
    if (old.len == 0) return tools.Output.err("old_string must not be empty");
    if (std.mem.eql(u8, old, new)) return tools.Output.err("old_string and new_string are identical");

    const path = try util.resolvePath(ctx.allocator, ctx.cwd, path_arg);
    defer ctx.allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "failed to read {s}: {s}", .{ path, @errorName(err) });
        return tools.Output.errOwned(msg);
    };
    const content = file.readToEndAlloc(ctx.allocator, 8 * 1024 * 1024) catch |err| {
        file.close();
        const msg = try std.fmt.allocPrint(ctx.allocator, "failed to read {s}: {s}", .{ path, @errorName(err) });
        return tools.Output.errOwned(msg);
    };
    file.close();
    defer ctx.allocator.free(content);

    const count = countMatches(content, old);
    if (count == 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "old_string not found in {s}", .{path});
        return tools.Output.errOwned(msg);
    }
    if (count > 1 and !replace_all) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "old_string matches {d} times in {s}; provide more surrounding context to make it unique, or set replace_all", .{ count, path });
        return tools.Output.errOwned(msg);
    }

    const first = std.mem.indexOf(u8, content, old) orelse 0;
    const first_line = 1 + std.mem.count(u8, content[0..first], "\n");

    const updated = if (replace_all)
        try std.mem.replaceOwned(u8, ctx.allocator, content, old, new)
    else
        try replaceOnce(ctx.allocator, content, old, new);
    defer ctx.allocator.free(updated);

    const out = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "failed to write {s}: {s}", .{ path, @errorName(err) });
        return tools.Output.errOwned(msg);
    };
    defer out.close();
    try out.writeAll(updated);

    const msg = if (count == 1)
        try std.fmt.allocPrint(ctx.allocator, "Edited {s}: replaced 1 occurrence (line {d})", .{ path, first_line })
    else
        try std.fmt.allocPrint(ctx.allocator, "Edited {s}: replaced {d} occurrences (first at line {d})", .{ path, count, first_line });
    return tools.Output.okOwned(msg);
}

fn countMatches(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |at| {
        n += 1;
        i = at + needle.len;
    }
    return n;
}

fn replaceOnce(allocator: std.mem.Allocator, hay: []const u8, old: []const u8, new: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, hay, old) orelse return allocator.dupe(u8, hay);
    var out = try allocator.alloc(u8, hay.len - old.len + new.len);
    @memcpy(out[0..at], hay[0..at]);
    @memcpy(out[at .. at + new.len], new);
    @memcpy(out[at + new.len ..], hay[at + old.len ..]);
    return out;
}

fn listFiles(ctx: *tools.Context, args: json.Value) !tools.Output {
    const path_arg = json.getString(args, "path") orelse ".";
    const glob = json.getString(args, "glob");
    const dir_path = try util.resolvePath(ctx.allocator, ctx.cwd, path_arg);
    defer ctx.allocator.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "{s} is not a directory: {s}", .{ dir_path, @errorName(err) });
        return tools.Output.errOwned(msg);
    };
    defer dir.close();

    var entries: std.ArrayList([]u8) = .empty;
    defer {
        for (entries.items) |e| ctx.allocator.free(e);
        entries.deinit(ctx.allocator);
    }

    if (glob == null) {
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
            const line = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ entry.name, suffix });
            try entries.append(ctx.allocator, line);
            if (entries.items.len >= util.max_list_entries) break;
        }
    } else {
        try walkGlob(ctx.allocator, dir, "", glob.?, &entries);
    }

    const lessThan = struct {
        fn f(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.f;
    std.mem.sort([]u8, entries.items, {}, lessThan);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    if (entries.items.len == 0) {
        try out.appendSlice(ctx.allocator, "(empty)");
    } else {
        for (entries.items, 0..) |e, i| {
            if (i != 0) try out.append(ctx.allocator, '\n');
            try out.appendSlice(ctx.allocator, e);
        }
    }
    return tools.Output.okOwned(try out.toOwnedSlice(ctx.allocator));
}

fn walkGlob(allocator: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8, glob: []const u8, out: *std.ArrayList([]u8)) !void {
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (out.items.len >= util.max_list_entries) return;
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        const rel = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(rel);
        if (entry.kind == .directory) {
            var child = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer child.close();
            try walkGlob(allocator, child, rel, glob, out);
        } else if (globMatch(glob, rel) or globMatch(glob, entry.name)) {
            try out.append(allocator, try allocator.dupe(u8, rel));
        }
    }
}

/// Tiny glob: `*` matches any run that is not `/`, `**` matches anything.
fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globRec(pattern, path);
}

fn globRec(pat: []const u8, s: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    if (pat.len >= 2 and pat[0] == '*' and pat[1] == '*') {
        const rest = if (pat.len > 2 and pat[2] == '/') pat[3..] else pat[2..];
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (globRec(rest, s[i..])) return true;
        }
        return false;
    }
    if (pat[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (i > 0 and s[i - 1] == '/') break;
            if (globRec(pat[1..], s[i..])) return true;
        }
        return false;
    }
    if (s.len == 0) return false;
    if (pat[0] != '?' and pat[0] != s[0]) return false;
    return globRec(pat[1..], s[1..]);
}

fn searchFiles(ctx: *tools.Context, args: json.Value) !tools.Output {
    const pattern = json.getString(args, "pattern") orelse return tools.Output.err("pattern must not be empty");
    if (pattern.len == 0) return tools.Output.err("pattern must not be empty");
    const path_arg = json.getString(args, "path") orelse ".";
    const glob = json.getString(args, "glob");

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);

    if (commandExists("rg")) {
        try argv.appendSlice(ctx.allocator, &.{ "rg", "--line-number", "--no-heading", "--color", "never", "--max-columns", "500" });
        if (glob) |g| {
            try argv.append(ctx.allocator, "--glob");
            try argv.append(ctx.allocator, g);
        }
        try argv.appendSlice(ctx.allocator, &.{ "--regexp", pattern, "--", path_arg });
    } else {
        try argv.appendSlice(ctx.allocator, &.{ "grep", "-r", "-n", "-I", "-E" });
        if (glob) |g| {
            const include = try std.fmt.allocPrint(ctx.allocator, "--include={s}", .{g});
            defer ctx.allocator.free(include);
            try argv.append(ctx.allocator, try ctx.allocator.dupe(u8, include));
        }
        try argv.appendSlice(ctx.allocator, &.{ "-e", pattern, "--", path_arg });
    }

    const result = runCapture(ctx.allocator, argv.items, ctx.cwd) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "search failed: {s}", .{@errorName(err)});
        return tools.Output.errOwned(msg);
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    if (result.code == 0) {
        const trimmed = std.mem.trimRight(u8, result.stdout, "\n");
        return tools.Output.okOwned(try util.truncate(ctx.allocator, trimmed, util.max_output_bytes));
    }
    if (result.code == 1) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "No matches for pattern '{s}'.", .{pattern});
        return tools.Output.okOwned(msg);
    }
    const detail = if (result.stderr.len == 0) "search failed" else std.mem.trimRight(u8, result.stderr, "\n");
    return tools.Output.errOwned(try ctx.allocator.dupe(u8, detail));
}

const Capture = struct { stdout: []u8, stderr: []u8, code: u8 };

fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !Capture {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 2 * 1024 * 1024);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 256 * 1024);
    errdefer allocator.free(stderr);
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .stdout = stdout, .stderr = stderr, .code = code };
}

fn commandExists(name: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "which", name },
    }) catch return false;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    return result.term == .Exited and result.term.Exited == 0;
}

test "globMatch" {
    try std.testing.expect(globMatch("**/*.zig", "src/main.zig"));
    try std.testing.expect(globMatch("*.md", "README.md"));
    try std.testing.expect(!globMatch("*.md", "src/main.zig"));
}

test "countMatches" {
    try std.testing.expectEqual(@as(usize, 2), countMatches("aa-aa", "aa"));
    try std.testing.expectEqual(@as(usize, 0), countMatches("abc", "z"));
}

test "write read edit in a temp dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realpath(".", &path_buf);

    var registry = tools.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try register(&registry);

    var ctx = tools.Context{ .allocator = std.testing.allocator, .cwd = cwd, .home = cwd };
    defer ctx.deinit();

    const write_args = try json.parse(std.testing.allocator, "{\"path\":\"n.txt\",\"content\":\"alpha\\n\"}");
    defer write_args.deinit();
    const w = try registry.dispatch(&ctx, "write_file", write_args.value);
    defer w.deinit(std.testing.allocator);
    try std.testing.expect(!w.is_error);

    const read_args = try json.parse(std.testing.allocator, "{\"path\":\"n.txt\"}");
    defer read_args.deinit();
    const r = try registry.dispatch(&ctx, "read_file", read_args.value);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.content, "alpha") != null);

    const edit_args = try json.parse(std.testing.allocator, "{\"path\":\"n.txt\",\"old_string\":\"alpha\",\"new_string\":\"beta\"}");
    defer edit_args.deinit();
    const e = try registry.dispatch(&ctx, "edit_file", edit_args.value);
    defer e.deinit(std.testing.allocator);
    try std.testing.expect(!e.is_error);
}
