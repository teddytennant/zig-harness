const std = @import("std");
const json = @import("../json.zig");
const lua = @import("../lua.zig");
const util = @import("../util.zig");
const tools = @import("mod.zig");

pub fn register(registry: *tools.Registry) !void {
    try registry.register(.{
        .name = "run_code",
        .description =
            \\Run a LuaJIT program in-process. Print what you want to keep. Host helpers live under `wizard` (read_file, write_file). Arguments for a scripted tool arrive as the global `args`. Use this when a sequence of file or string operations would otherwise be many tool calls.
        ,
        .parameters_json =
            \\{"type":"object","properties":{"code":{"type":"string","description":"A LuaJIT program. Print what you want to keep."},"timeout_secs":{"type":"integer","description":"Compute budget in seconds (default 30, max 120)."}},"required":["code"]}
        ,
        .access = .execute,
        .run = runCode,
    });
}

fn runCode(ctx: *tools.Context, args: json.Value) !tools.Output {
    const code = json.getString(args, "code") orelse return tools.Output.err("code must be a non-empty LuaJIT program");
    if (std.mem.trim(u8, code, " \t\n").len == 0) {
        return tools.Output.err("code must be a non-empty LuaJIT program");
    }
    const result = lua.run(ctx.allocator, ctx.cwd, code, args, .full) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "luajit failed: {s}", .{@errorName(err)});
        return tools.Output.errOwned(msg);
    };
    defer result.deinit(ctx.allocator);
    const text = try result.text(ctx.allocator);
    if (result.err != null) return tools.Output.errOwned(text);
    return tools.Output.okOwned(try util.truncate(ctx.allocator, text, util.max_output_bytes));
}

/// Load `~/.zig-harness/tools/*.toml` plus bundled `lua/*.toml` as scripted tools.
pub fn loadScripted(registry: *tools.Registry, allocator: std.mem.Allocator, home: []const u8) !usize {
    var n: usize = 0;
    const dir_path = try std.fs.path.join(allocator, &.{ home, "tools" });
    defer allocator.free(dir_path);
    n += loadDir(registry, allocator, dir_path) catch 0;
    return n;
}

fn loadDir(registry: *tools.Registry, allocator: std.mem.Allocator, dir_path: []const u8) !usize {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        _ = allocator;
        _ = registry;
        n += 1;
    }
    return n;
}

pub fn runScript(ctx: *tools.Context, source: []const u8, args: json.Value) !tools.Output {
    const result = lua.run(ctx.allocator, ctx.cwd, source, args, .full) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "luajit failed: {s}", .{@errorName(err)});
        return tools.Output.errOwned(msg);
    };
    defer result.deinit(ctx.allocator);
    const text = try result.text(ctx.allocator);
    if (result.err != null) return tools.Output.errOwned(text);
    return tools.Output.okOwned(text);
}
