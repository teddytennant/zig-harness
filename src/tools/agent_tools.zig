const std = @import("std");
const json = @import("../json.zig");
const tools = @import("mod.zig");

pub fn register(registry: *tools.Registry) !void {
    try registry.register(.{
        .name = "exit_plan",
        .description =
            \\Finish plan mode by presenting your implementation plan for review. Call this only while in plan mode, after investigating with read-only tools. The plan is saved to .wizard/plan.md and reviewed; if approved you may execute it, if rejected you receive feedback and stay in plan mode.
        ,
        .parameters_json =
            \\{"type":"object","properties":{"plan":{"type":"string","description":"The full implementation plan, as markdown"}},"required":["plan"]}
        ,
        .access = .execute,
        .run = exitPlan,
    });
    try registry.register(.{
        .name = "interview",
        .description =
            \\Ask the user a short batch of clarifying questions during plan mode, before you commit to a plan. Use it only when you have genuine open questions whose answers would change your approach (scope, trade-offs, ambiguous intent) — not for things you can determine by reading the code. Each question may offer suggested options; the user can pick one or write their own. Their answers come back as the tool result. Read-only, so it works mid-plan.
        ,
        .parameters_json =
            \\{"type":"object","properties":{"questions":{"type":"array","description":"The clarifying questions to ask, in order (at most 6).","items":{"type":"object","properties":{"question":{"type":"string"},"options":{"type":"array","items":{"type":"string"}}},"required":["question"]}}},"required":["questions"]}
        ,
        .access = .read_only,
        .run = interview,
    });
    try registry.register(.{
        .name = "compact",
        .description =
            \\Summarize older conversation history into a progress note right now (keeps the recent tail verbatim). Call after a long investigation, a finished sub-goal, or when a pressure signal is elevated/high. No parameters.
        ,
        .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
        .access = .read_only,
        .run = compact,
    });
    try registry.register(.{
        .name = "spawn_subagent",
        .description =
            \\Delegate a self-contained sub-task to an isolated subagent. It runs its own loop with a fresh context and scoped tools, then returns one final report. `task` is the ONLY context the subagent gets besides its own prompt. Available: worker, documenter, tester, reviewer.
        ,
        .parameters_json =
            \\{"type":"object","properties":{"subagent":{"type":"string","description":"Name of the subagent to use"},"task":{"type":"string","description":"Self-contained task description with all needed context"},"background":{"type":"boolean","description":"Run detached (not yet supported; treated as foreground)"}},"required":["subagent","task"]}
        ,
        .access = .execute,
        .run = spawnSubagent,
    });
}

fn exitPlan(ctx: *tools.Context, args: json.Value) !tools.Output {
    const plan = json.getString(args, "plan") orelse return tools.Output.err("plan is required");
    if (!ctx.plan_mode) {
        return tools.Output.err("exit_plan is only available while plan mode is active");
    }
    const dir = try std.fs.path.join(ctx.allocator, &.{ ctx.cwd, ".wizard" });
    defer ctx.allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};
    const path = try std.fs.path.join(ctx.allocator, &.{ dir, "plan.md" });
    defer ctx.allocator.free(path);
    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "failed to write plan: {s}", .{@errorName(err)});
        return tools.Output.errOwned(msg);
    };
    defer file.close();
    try file.writeAll(plan);

    if (ctx.last_plan) |old| ctx.allocator.free(old);
    ctx.last_plan = try ctx.allocator.dupe(u8, plan);

    if (ctx.omakase) {
        ctx.plan_mode = false;
        ctx.omakase = false;
        return tools.Output.ok("Plan auto-approved (omakase). Execute it.");
    }
    ctx.plan_mode = false;
    return tools.Output.ok("Plan saved to .wizard/plan.md and approved. Execute it.");
}

fn interview(ctx: *tools.Context, args: json.Value) !tools.Output {
    const questions = json.objectGet(args, "questions") orelse return tools.Output.err("questions is required");
    if (questions != .array) return tools.Output.err("questions must be an array");
    if (!ctx.plan_mode) {
        return tools.Output.err("interview is for plan mode; ask in your reply instead");
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "Headless run: no human to interview. Resolve these yourself and call exit_plan:\n");
    for (questions.array.items, 0..) |q, i| {
        const text = json.getString(q, "question") orelse continue;
        try out.writer(ctx.allocator).print("{d}. {s}\n", .{ i + 1, text });
    }
    return tools.Output.okOwned(try out.toOwnedSlice(ctx.allocator));
}

fn compact(ctx: *tools.Context, _: json.Value) !tools.Output {
    ctx.compact_requested = true;
    return tools.Output.ok("compact requested: the agent loop will summarize older history before the next model step.");
}

fn spawnSubagent(ctx: *tools.Context, args: json.Value) !tools.Output {
    const name = json.getString(args, "subagent") orelse return tools.Output.err("subagent is required");
    const task = json.getString(args, "task") orelse return tools.Output.err("task is required");
    // Nested model loop lives in agent.zig; here we just record the request so
    // the parent loop can run it. Returning a stub keeps the tool callable in
    // unit tests that have no provider.
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "subagent '{s}' accepted task ({d} bytes). The parent loop will run it and inject the report.",
        .{ name, task.len },
    );
    return tools.Output.okOwned(msg);
}
