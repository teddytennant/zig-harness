const std = @import("std");
const json = @import("../json.zig");
const tools = @import("mod.zig");

pub fn register(registry: *tools.Registry) !void {
    try registry.register(.{
        .name = "todo",
        .description =
            \\Maintain your working todo list for the current task. Action "write" replaces the entire list (pass every item, including completed ones, each as {content, status}); action "read" returns the current list. Statuses: pending, in_progress, completed — keep exactly one item in_progress at a time and mark items completed as soon as they are done.
        ,
        .parameters_json =
            \\{"type":"object","properties":{"action":{"type":"string","enum":["write","read"],"description":"write replaces the whole list; read returns it"},"items":{"type":"array","description":"The full todo list (write only)","items":{"type":"object","properties":{"content":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["content","status"]}}},"required":["action"]}
        ,
        .access = .read_only,
        .run = todo,
    });
}

fn todo(ctx: *tools.Context, args: json.Value) !tools.Output {
    const action = json.getString(args, "action") orelse return tools.Output.err("action is required");
    if (std.mem.eql(u8, action, "read")) {
        return tools.Output.okOwned(try render(ctx));
    }
    if (!std.mem.eql(u8, action, "write")) {
        return tools.Output.err("action must be write or read");
    }
    const items_v = json.objectGet(args, "items") orelse return tools.Output.err("action \"write\" requires `items` (the full list)");
    if (items_v != .array) return tools.Output.err("`items` must be an array");

    for (ctx.todos.items) |item| {
        ctx.allocator.free(item.content);
        ctx.allocator.free(item.status);
    }
    ctx.todos.clearRetainingCapacity();

    for (items_v.array.items) |item| {
        const content = json.getString(item, "content") orelse continue;
        const status = json.getString(item, "status") orelse "pending";
        try ctx.todos.append(ctx.allocator, .{
            .content = try ctx.allocator.dupe(u8, content),
            .status = try ctx.allocator.dupe(u8, status),
        });
    }

    var done: usize = 0;
    for (ctx.todos.items) |item| {
        if (std.mem.eql(u8, item.status, "completed")) done += 1;
    }
    const body = try render(ctx);
    const msg = try std.fmt.allocPrint(ctx.allocator, "todo list updated — {d}/{d} done\n{s}", .{ done, ctx.todos.items.len, body });
    ctx.allocator.free(body);
    return tools.Output.okOwned(msg);
}

fn render(ctx: *tools.Context) ![]u8 {
    if (ctx.todos.items.len == 0) return ctx.allocator.dupe(u8, "(empty todo list)");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    for (ctx.todos.items) |item| {
        const mark: []const u8 = if (std.mem.eql(u8, item.status, "completed"))
            "x"
        else if (std.mem.eql(u8, item.status, "in_progress"))
            ">"
        else
            " ";
        try out.writer(ctx.allocator).print("[{s}] {s}\n", .{ mark, item.content });
    }
    return out.toOwnedSlice(ctx.allocator);
}
