const std = @import("std");
const json = @import("../json.zig");
const util = @import("../util.zig");
const tools = @import("mod.zig");

pub fn register(registry: *tools.Registry) !void {
    try registry.register(.{
        .name = "memory",
        .description =
            \\Persist a fact about this project or its user across sessions. Actions: 'save' (record or update a durable fact: needs type, description, content), 'read' (full body plus linked memories), 'delete' (drop a wrong/obsolete one). Types: user, feedback, project, reference. Before you save or delete, read `manual` topic `memory`: it says what earns a place and what must never be written down. Names are kebab-case; descriptions are one line.
        ,
        .parameters_json =
            \\{"type":"object","properties":{"action":{"type":"string","enum":["save","read","delete"],"description":"What to do with the memory"},"name":{"type":"string","description":"Kebab-case memory name (lowercase letters, digits, hyphens). Reuse an existing name to update that memory in place."},"type":{"type":"string","enum":["user","feedback","project","reference"],"description":"What the memory is about (required for save)"},"description":{"type":"string","description":"One-line summary shown in the memory index (required for save)"},"content":{"type":"string","description":"The fact to remember, markdown allowed, [[links]] to related memories allowed (required for save)"}},"required":["action","name"]}
        ,
        .access = .read_only,
        .run = memory,
    });
}

fn projectSlug(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(cwd);
    return std.fmt.allocPrint(allocator, "{x}", .{hasher.final()});
}

fn memoryDir(ctx: *tools.Context) ![]u8 {
    const slug = try projectSlug(ctx.allocator, ctx.cwd);
    defer ctx.allocator.free(slug);
    return std.fs.path.join(ctx.allocator, &.{ ctx.home, "memory", slug });
}

fn memoryPath(ctx: *tools.Context, name: []const u8) ![]u8 {
    const dir = try memoryDir(ctx);
    defer ctx.allocator.free(dir);
    const file = try std.fmt.allocPrint(ctx.allocator, "{s}.md", .{name});
    defer ctx.allocator.free(file);
    return std.fs.path.join(ctx.allocator, &.{ dir, file });
}

fn memory(ctx: *tools.Context, args: json.Value) !tools.Output {
    const action = json.getString(args, "action") orelse return tools.Output.err("action is required");
    const name = json.getString(args, "name") orelse return tools.Output.err("name is required");
    if (!util.kebabOk(name)) return tools.Output.err("name must be kebab-case (lowercase letters, digits, hyphens)");

    if (std.mem.eql(u8, action, "save")) {
        const kind = json.getString(args, "type") orelse return tools.Output.err("action 'save' requires 'type'");
        if (!(std.mem.eql(u8, kind, "user") or std.mem.eql(u8, kind, "feedback") or
            std.mem.eql(u8, kind, "project") or std.mem.eql(u8, kind, "reference")))
        {
            return tools.Output.err("type must be user, feedback, project, or reference");
        }
        const description = json.getString(args, "description") orelse return tools.Output.err("action 'save' requires 'description'");
        const content = json.getString(args, "content") orelse return tools.Output.err("action 'save' requires 'content'");

        const dir = try memoryDir(ctx);
        defer ctx.allocator.free(dir);
        std.fs.cwd().makePath(dir) catch |err| {
            const msg = try std.fmt.allocPrint(ctx.allocator, "failed to create memory dir: {s}", .{@errorName(err)});
            return tools.Output.errOwned(msg);
        };
        const path = try memoryPath(ctx, name);
        defer ctx.allocator.free(path);
        const body = try std.fmt.allocPrint(ctx.allocator, "---\ntype: {s}\ndescription: {s}\n---\n\n{s}\n", .{ kind, description, content });
        defer ctx.allocator.free(body);
        const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
            const msg = try std.fmt.allocPrint(ctx.allocator, "failed to write memory: {s}", .{@errorName(err)});
            return tools.Output.errOwned(msg);
        };
        defer file.close();
        try file.writeAll(body);
        const msg = try std.fmt.allocPrint(ctx.allocator, "Saved memory '{s}' ({s}). It will appear in the system prompt's memory index next session.", .{ name, kind });
        return tools.Output.okOwned(msg);
    }

    if (std.mem.eql(u8, action, "read")) {
        const path = try memoryPath(ctx, name);
        defer ctx.allocator.free(path);
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            const msg = try std.fmt.allocPrint(ctx.allocator, "no memory named '{s}'", .{name});
            return tools.Output.errOwned(msg);
        };
        defer file.close();
        const body = try file.readToEndAlloc(ctx.allocator, 256 * 1024);
        return tools.Output.okOwned(body);
    }

    if (std.mem.eql(u8, action, "delete")) {
        const path = try memoryPath(ctx, name);
        defer ctx.allocator.free(path);
        std.fs.deleteFileAbsolute(path) catch {
            const msg = try std.fmt.allocPrint(ctx.allocator, "no memory named '{s}'", .{name});
            return tools.Output.errOwned(msg);
        };
        const msg = try std.fmt.allocPrint(ctx.allocator, "Deleted memory '{s}'.", .{name});
        return tools.Output.okOwned(msg);
    }

    const msg = try std.fmt.allocPrint(ctx.allocator, "unknown action '{s}' (save|read|delete)", .{action});
    return tools.Output.errOwned(msg);
}

pub fn indexMarkdown(allocator: std.mem.Allocator, home: []const u8, cwd: []const u8) ![]u8 {
    const slug = try projectSlug(allocator, cwd);
    defer allocator.free(slug);
    const dir_path = try std.fs.path.join(allocator, &.{ home, "memory", slug });
    defer allocator.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch {
        return allocator.dupe(u8, "");
    };
    defer dir.close();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Saved memories:\n");
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const name = entry.name[0 .. entry.name.len - 3];
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();
        const body = file.readToEndAlloc(allocator, 64 * 1024) catch continue;
        defer allocator.free(body);
        const kind = frontmatterField(body, "type") orelse "project";
        const desc = frontmatterField(body, "description") orelse "";
        try out.writer(allocator).print("- `{s}` ({s}): {s}\n", .{ name, kind, desc });
        n += 1;
    }
    if (n == 0) {
        out.deinit(allocator);
        return allocator.dupe(u8, "");
    }
    return out.toOwnedSlice(allocator);
}

fn frontmatterField(body: []const u8, field: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "---")) continue;
        if (std.mem.startsWith(u8, line, field)) {
            if (line.len > field.len + 2 and line[field.len] == ':') {
                return std.mem.trim(u8, line[field.len + 1 ..], " \t");
            }
        }
    }
    return null;
}
