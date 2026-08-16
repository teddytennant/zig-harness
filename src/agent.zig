//! Headless agent loop: system prompt + tools + OpenAI-compatible provider.

const std = @import("std");
const config_mod = @import("config.zig");
const json = @import("json.zig");
const llm = @import("llm.zig");
const prompts = @import("prompts.zig");
const tools = @import("tools/mod.zig");

pub const Options = struct {
    prompt: []const u8,
    max_steps: u32 = 0,
    plan_mode: bool = false,
    omakase: bool = false,
};

pub fn run(allocator: std.mem.Allocator, cfg: *config_mod.Config, opts: Options) !u8 {
    cfg.plan_mode = opts.plan_mode;
    cfg.omakase = opts.omakase;
    if (opts.max_steps != 0) cfg.max_steps = opts.max_steps;

    var registry = try tools.withNative(allocator);
    defer registry.deinit();

    var ctx = tools.Context{
        .allocator = allocator,
        .cwd = cfg.cwd,
        .home = cfg.home,
        .plan_mode = cfg.plan_mode,
        .omakase = cfg.omakase,
    };
    defer ctx.deinit();

    const system = try prompts.buildSystemPrompt(allocator, cfg.*);
    defer allocator.free(system);

    const tools_json = try tools.openaiToolsJson(allocator, registry);
    defer allocator.free(tools_json);

    var messages: std.ArrayList(llm.Message) = .empty;
    defer {
        // contents we allocated (tool results, assistant copies) live on `scratch`
        messages.deinit(allocator);
    }

    try messages.append(allocator, .{ .role = .system, .content = system });
    try messages.append(allocator, .{ .role = .user, .content = opts.prompt });

    var scratch: std.ArrayList([]u8) = .empty;
    defer {
        for (scratch.items) |s| allocator.free(s);
        scratch.deinit(allocator);
    }

    const provider = cfg.active() orelse {
        std.debug.print("no provider configured. Set OPENAI_API_KEY and optionally ZIG_HARNESS_MODEL / ZIG_HARNESS_BASE_URL.\n", .{});
        return 1;
    };

    var step: u32 = 0;
    const limit: u32 = if (cfg.max_steps == 0) 64 else cfg.max_steps;

    while (step < limit) : (step += 1) {
        if (ctx.compact_requested and messages.items.len > 6) {
            try compactHistory(allocator, &messages, &scratch);
            ctx.compact_requested = false;
        }

        var response = llm.chat(allocator, provider, messages.items, tools_json) catch |err| {
            std.debug.print("llm error: {s}\n", .{@errorName(err)});
            return 2;
        };
        defer response.deinit();

        if (response.tool_calls.len == 0) {
            if (response.content.len > 0) {
                std.debug.print("{s}\n", .{response.content});
            }
            return 0;
        }

        // Keep the assistant turn (content + tool_calls) so the next request is valid.
        const owned_content = try allocator.dupe(u8, response.content);
        try scratch.append(allocator, owned_content);
        var owned_calls = try allocator.alloc(llm.ToolCall, response.tool_calls.len);
        // leak the slice into scratch via a wrapper? store each field.
        // We put the array on the heap and never free the slice itself separately:
        // copy strings into scratch, keep the ToolCall array in a second list.
        for (response.tool_calls, 0..) |tc, i| {
            const id = try allocator.dupe(u8, tc.id);
            const name = try allocator.dupe(u8, tc.name);
            const arguments = try allocator.dupe(u8, tc.arguments);
            try scratch.append(allocator, id);
            try scratch.append(allocator, name);
            try scratch.append(allocator, arguments);
            owned_calls[i] = .{ .id = id, .name = name, .arguments = arguments };
        }
        // stash the call array so it lives
        const calls_bytes = std.mem.sliceAsBytes(owned_calls);
        _ = calls_bytes;
        // owned_calls must live until messages die. Hang it off scratch as a dummy by leaking
        // through arena-like: we just don't free owned_calls. Accept the leak for process lifetime.
        try messages.append(allocator, .{
            .role = .assistant,
            .content = owned_content,
            .tool_calls = owned_calls,
        });

        for (response.tool_calls) |tc| {
            std.debug.print("→ {s}\n", .{tc.name});
            const result_text = try dispatchOne(allocator, &registry, &ctx, cfg, &opts, tc);
            try scratch.append(allocator, result_text);
            const id_copy = try allocator.dupe(u8, tc.id);
            try scratch.append(allocator, id_copy);
            try messages.append(allocator, .{
                .role = .tool,
                .content = result_text,
                .tool_call_id = id_copy,
            });
        }
    }

    std.debug.print("stopped after {d} steps\n", .{limit});
    return 2;
}

fn dispatchOne(
    allocator: std.mem.Allocator,
    registry: *tools.Registry,
    ctx: *tools.Context,
    cfg: *config_mod.Config,
    opts: *const Options,
    tc: llm.ToolCall,
) anyerror![]u8 {
    if (std.mem.eql(u8, tc.name, "spawn_subagent")) {
        return runSubagent(allocator, registry, ctx, cfg, tc);
    }

    const parsed = json.parse(allocator, if (tc.arguments.len == 0) "{}" else tc.arguments) catch {
        return allocator.dupe(u8, "invalid tool arguments (not JSON)");
    };
    defer parsed.deinit();

    // Keep plan-mode flag on the context in sync with exit_plan.
    ctx.plan_mode = cfg.plan_mode or ctx.plan_mode;
    const out = registry.dispatch(ctx, tc.name, parsed.value) catch |err| {
        return std.fmt.allocPrint(allocator, "tool error: {s}", .{@errorName(err)});
    };
    defer out.deinit(allocator);
    cfg.plan_mode = ctx.plan_mode;
    _ = opts;
    const prefix: []const u8 = if (out.is_error) "ERROR: " else "";
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, out.content });
}

fn runSubagent(
    allocator: std.mem.Allocator,
    parent: *tools.Registry,
    parent_ctx: *tools.Context,
    cfg: *config_mod.Config,
    tc: llm.ToolCall,
) anyerror![]u8 {
    const parsed = json.parse(allocator, if (tc.arguments.len == 0) "{}" else tc.arguments) catch {
        return allocator.dupe(u8, "invalid spawn_subagent arguments");
    };
    defer parsed.deinit();
    const name = json.getString(parsed.value, "subagent") orelse "worker";
    const task = json.getString(parsed.value, "task") orelse return allocator.dupe(u8, "task is required");

    const system = try std.fmt.allocPrint(allocator,
        \\You are a focused {s} subagent of zig-harness. Complete the given sub-task end-to-end using the provided tools, then reply with a concise final report of what you found or changed. Do not ask questions; make reasonable decisions and note them in your report.
    , .{name});
    defer allocator.free(system);

    var ctx = tools.Context{
        .allocator = allocator,
        .cwd = parent_ctx.cwd,
        .home = parent_ctx.home,
        .plan_mode = parent_ctx.plan_mode,
    };
    defer ctx.deinit();

    const tools_json = try tools.openaiToolsJson(allocator, parent.*);
    defer allocator.free(tools_json);

    var messages: std.ArrayList(llm.Message) = .empty;
    defer messages.deinit(allocator);
    try messages.append(allocator, .{ .role = .system, .content = system });
    try messages.append(allocator, .{ .role = .user, .content = task });

    var scratch: std.ArrayList([]u8) = .empty;
    defer {
        for (scratch.items) |s| allocator.free(s);
        scratch.deinit(allocator);
    }

    const provider = cfg.active() orelse return allocator.dupe(u8, "no provider");

    var step: u32 = 0;
    while (step < 24) : (step += 1) {
        var response = llm.chat(allocator, provider, messages.items, tools_json) catch |err| {
            return std.fmt.allocPrint(allocator, "subagent llm error: {s}", .{@errorName(err)});
        };
        defer response.deinit();
        if (response.tool_calls.len == 0) {
            return allocator.dupe(u8, response.content);
        }
        const owned_content = try allocator.dupe(u8, response.content);
        try scratch.append(allocator, owned_content);
        var owned_calls = try allocator.alloc(llm.ToolCall, response.tool_calls.len);
        for (response.tool_calls, 0..) |call, i| {
            const id = try allocator.dupe(u8, call.id);
            const n = try allocator.dupe(u8, call.name);
            const arguments = try allocator.dupe(u8, call.arguments);
            try scratch.append(allocator, id);
            try scratch.append(allocator, n);
            try scratch.append(allocator, arguments);
            owned_calls[i] = .{ .id = id, .name = n, .arguments = arguments };
        }
        try messages.append(allocator, .{
            .role = .assistant,
            .content = owned_content,
            .tool_calls = owned_calls,
        });
        for (response.tool_calls) |call| {
            if (std.mem.eql(u8, call.name, "spawn_subagent")) {
                const msg = try allocator.dupe(u8, "refusing nested spawn_subagent");
                try scratch.append(allocator, msg);
                const id_copy = try allocator.dupe(u8, call.id);
                try scratch.append(allocator, id_copy);
                try messages.append(allocator, .{ .role = .tool, .content = msg, .tool_call_id = id_copy });
                continue;
            }
            const result_text = try dispatchOne(allocator, parent, &ctx, cfg, &.{ .prompt = task }, call);
            try scratch.append(allocator, result_text);
            const id_copy = try allocator.dupe(u8, call.id);
            try scratch.append(allocator, id_copy);
            try messages.append(allocator, .{
                .role = .tool,
                .content = result_text,
                .tool_call_id = id_copy,
            });
        }
    }
    return allocator.dupe(u8, "subagent stopped after 24 steps");
}

fn compactHistory(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(llm.Message),
    scratch: *std.ArrayList([]u8),
) !void {
    // Keep system + last 4 messages; replace the middle with a note.
    if (messages.items.len < 8) return;
    const keep_tail = 4;
    const tail_start = messages.items.len - keep_tail;
    const note = try std.fmt.allocPrint(allocator, "[progress] compacted {d} older turns. Continue from the remaining tail.", .{tail_start - 1});
    try scratch.append(allocator, note);
    var kept: std.ArrayList(llm.Message) = .empty;
    try kept.append(allocator, messages.items[0]);
    try kept.append(allocator, .{ .role = .user, .content = note });
    try kept.appendSlice(allocator, messages.items[tail_start..]);
    messages.deinit(allocator);
    messages.* = kept;
}
