const std = @import("std");
const json = @import("../json.zig");
const prompts = @import("../prompts.zig");
const tools = @import("mod.zig");

pub fn register(registry: *tools.Registry) !void {
    try registry.register(.{
        .name = "manual",
        .description =
            \\Read one section of your operating charter (WIZARD.md) in full: the capability ladder and what each rung costs, the browser-use recipe, how to delegate to subagents, the grounding rules, the publish flow, and the guardrails. Your system prompt carries only the index of these; this is where the text lives. Pass 'topic' as an advertised id ('recipe-browser-use'), a section number ('2'), or a word from the title; omit it to list every topic. Everything it returns is compiled into this binary, so a call is instant and costs nothing but the text itself. Look a section up before you act on its subject, and look one up speculatively rather than guessing what it says.
        ,
        .parameters_json =
            \\{"type":"object","properties":{"topic":{"type":"string","description":"Topic id as advertised in the system prompt (e.g. 'recipe-browser-use'), a charter section number ('2'), or any word from a section title. Omit to list every available topic."}}}
        ,
        .access = .read_only,
        .run = manual,
    });
}

fn manual(ctx: *tools.Context, args: json.Value) !tools.Output {
    const topic = json.getString(args, "topic") orelse
        json.getString(args, "section") orelse
        json.getString(args, "id") orelse
        json.getString(args, "name") orelse
        json.getString(args, "page");

    if (topic == null or topic.?.len == 0) {
        return tools.Output.okOwned(try prompts.listTopics(ctx.allocator));
    }
    if (prompts.lookup(topic.?)) |page| {
        const text = try std.fmt.allocPrint(ctx.allocator, "# {s}\n\n{s}", .{ page.title, page.body });
        return tools.Output.okOwned(text);
    }
    const listed = try prompts.listTopics(ctx.allocator);
    defer ctx.allocator.free(listed);
    const msg = try std.fmt.allocPrint(ctx.allocator, "no manual page matches '{s}'. Topics:\n{s}", .{ topic.?, listed });
    return tools.Output.errOwned(msg);
}
