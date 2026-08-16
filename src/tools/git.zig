const std = @import("std");
const json = @import("../json.zig");
const util = @import("../util.zig");
const tools = @import("mod.zig");

pub fn register(registry: *tools.Registry) !void {
    try registry.register(.{
        .name = "git_status",
        .description = "Show the git working tree status of the project (branch, staged, modified, and untracked files).",
        .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
        .access = .read_only,
        .run = gitStatus,
    });
    try registry.register(.{
        .name = "git_diff",
        .description = "Show the git diff of the project: unstaged changes by default, staged with staged=true, optionally limited to one path.",
        .parameters_json =
            \\{"type":"object","properties":{"staged":{"type":"boolean","description":"Diff staged changes instead of the working tree"},"path":{"type":"string","description":"Limit the diff to this path"}}}
        ,
        .access = .read_only,
        .run = gitDiff,
    });
}

fn runGit(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !struct { stdout: []u8, stderr: []u8, code: u8 } {
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

fn gitStatus(ctx: *tools.Context, _: json.Value) !tools.Output {
    const result = runGit(ctx.allocator, ctx.cwd, &.{ "git", "status", "--porcelain=v1", "-b" }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "git status failed: {s}", .{@errorName(err)});
        return tools.Output.errOwned(msg);
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    if (result.code != 0) {
        const detail = if (result.stderr.len == 0) "git status failed" else std.mem.trimRight(u8, result.stderr, "\n");
        return tools.Output.errOwned(try ctx.allocator.dupe(u8, detail));
    }
    const status = std.mem.trimRight(u8, result.stdout, "\n");
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, status, '\n');
    while (it.next()) |_| lines += 1;
    if (lines <= 1) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "{s}\n(clean working tree)", .{status});
        return tools.Output.okOwned(msg);
    }
    return tools.Output.okOwned(try ctx.allocator.dupe(u8, status));
}

fn gitDiff(ctx: *tools.Context, args: json.Value) !tools.Output {
    const staged = json.getBool(args, "staged") orelse false;
    const path = json.getString(args, "path");

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    try argv.appendSlice(ctx.allocator, &.{ "git", "diff" });
    if (staged) try argv.append(ctx.allocator, "--cached");
    if (path) |p| {
        try argv.append(ctx.allocator, "--");
        try argv.append(ctx.allocator, p);
    }

    const result = runGit(ctx.allocator, ctx.cwd, argv.items) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "git diff failed: {s}", .{@errorName(err)});
        return tools.Output.errOwned(msg);
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    if (result.code != 0) {
        const detail = if (result.stderr.len == 0) "git diff failed" else std.mem.trimRight(u8, result.stderr, "\n");
        return tools.Output.errOwned(try ctx.allocator.dupe(u8, detail));
    }
    const diff = std.mem.trimRight(u8, result.stdout, "\n");
    if (diff.len == 0) return tools.Output.ok("No changes.");
    return tools.Output.okOwned(try util.truncate(ctx.allocator, diff, util.max_output_bytes));
}
