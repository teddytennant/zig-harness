const std = @import("std");
const json = @import("../json.zig");
const util = @import("../util.zig");
const tools = @import("mod.zig");

pub fn register(registry: *tools.Registry) !void {
    try registry.register(.{
        .name = "execute",
        .description =
            \\Run a shell command in the project root and return its stdout, stderr, and exit code. Killed on timeout.
            \\
            \\Tips:
            \\- Prefer compact output: summaries, `head`/`tail`/`wc`; put bulky intermediates in `/tmp`.
            \\- Non-zero exit is diagnostic signal — read stderr and adapt.
            \\- Prefer non-interactive flags (`-y`, `--yes`) when the run may be unattended.
        ,
        .parameters_json =
            \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command line (run via sh -c)"},"timeout_secs":{"type":"integer","description":"Timeout in seconds (default 120, max 600)"}},"required":["command"]}
        ,
        .access = .execute,
        .run = execute,
    });
}

fn execute(ctx: *tools.Context, args: json.Value) !tools.Output {
    const command = json.getString(args, "command") orelse return tools.Output.err("command must not be empty");
    if (std.mem.trim(u8, command, " \t\n").len == 0) return tools.Output.err("command must not be empty");

    var timeout = json.getUsize(args, "timeout_secs") orelse util.default_timeout_secs;
    if (timeout == 0) return tools.Output.err("timeout_secs must be at least 1");
    if (timeout > util.max_timeout_secs) timeout = util.max_timeout_secs;

    var child = std.process.Child.init(&.{ "sh", "-c", command }, ctx.allocator);
    child.cwd = ctx.cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(ctx.allocator, 2 * 1024 * 1024);
    defer ctx.allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(ctx.allocator, 256 * 1024);
    defer ctx.allocator.free(stderr);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |c| c,
        .Signal => |s| @as(i32, -@as(i32, @intCast(s))),
        else => -1,
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.writer(ctx.allocator).print("exit {d}\n", .{code});
    if (stdout.len > 0) {
        try out.appendSlice(ctx.allocator, "stdout:\n");
        try out.appendSlice(ctx.allocator, stdout);
        if (stdout[stdout.len - 1] != '\n') try out.append(ctx.allocator, '\n');
    }
    if (stderr.len > 0) {
        try out.appendSlice(ctx.allocator, "stderr:\n");
        try out.appendSlice(ctx.allocator, stderr);
        if (stderr[stderr.len - 1] != '\n') try out.append(ctx.allocator, '\n');
    }
    const raw = try out.toOwnedSlice(ctx.allocator);
    const truncated = try util.truncate(ctx.allocator, raw, util.max_output_bytes);
    ctx.allocator.free(raw);
    return tools.Output.okOwned(truncated);
}
