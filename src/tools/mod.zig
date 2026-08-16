//! Tool contract, registry, and native implementations.

const std = @import("std");
const json = @import("../json.zig");
const util = @import("../util.zig");

pub const file = @import("file.zig");
pub const shell = @import("shell.zig");
pub const git = @import("git.zig");
pub const memory = @import("memory.zig");
pub const todo = @import("todo.zig");
pub const manual = @import("manual.zig");
pub const web = @import("web.zig");
pub const agent_tools = @import("agent_tools.zig");
pub const lua_tools = @import("lua_tools.zig");

pub const Access = enum { read_only, edit, execute };

pub const Output = struct {
    content: []const u8,
    is_error: bool = false,
    owned: bool = false,

    pub fn ok(text: []const u8) Output {
        return .{ .content = text, .is_error = false, .owned = false };
    }

    pub fn okOwned(text: []const u8) Output {
        return .{ .content = text, .is_error = false, .owned = true };
    }

    pub fn err(text: []const u8) Output {
        return .{ .content = text, .is_error = true, .owned = false };
    }

    pub fn errOwned(text: []const u8) Output {
        return .{ .content = text, .is_error = true, .owned = true };
    }

    pub fn deinit(self: Output, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.content);
    }
};

pub const TodoItem = struct {
    content: []const u8,
    status: []const u8,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    home: []const u8,
    plan_mode: bool = false,
    omakase: bool = false,
    todos: std.ArrayList(TodoItem) = .empty,
    last_plan: ?[]const u8 = null,
    compact_requested: bool = false,

    pub fn deinit(self: *Context) void {
        for (self.todos.items) |item| {
            self.allocator.free(item.content);
            self.allocator.free(item.status);
        }
        self.todos.deinit(self.allocator);
        if (self.last_plan) |p| self.allocator.free(p);
    }
};

pub const Fn = *const fn (ctx: *Context, args: json.Value) anyerror!Output;

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    access: Access,
    run: Fn,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    specs: std.ArrayList(Spec),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .specs = .empty };
    }

    pub fn deinit(self: *Registry) void {
        self.specs.deinit(self.allocator);
    }

    pub fn register(self: *Registry, spec: Spec) !void {
        try self.specs.append(self.allocator, spec);
    }

    pub fn get(self: Registry, name: []const u8) ?Spec {
        for (self.specs.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn dispatch(self: Registry, ctx: *Context, name: []const u8, args: json.Value) !Output {
        const spec = self.get(name) orelse {
            const msg = try std.fmt.allocPrint(ctx.allocator, "unknown tool '{s}'", .{name});
            return Output.errOwned(msg);
        };
        if (ctx.plan_mode and spec.access != .read_only and !std.mem.eql(u8, name, "exit_plan")) {
            return Output.err("plan mode is active: only read-only tools (and exit_plan) are allowed");
        }
        return spec.run(ctx, args);
    }
};

pub fn withNative(allocator: std.mem.Allocator) !Registry {
    var r = Registry.init(allocator);
    errdefer r.deinit();
    try file.register(&r);
    try shell.register(&r);
    try git.register(&r);
    try memory.register(&r);
    try todo.register(&r);
    try manual.register(&r);
    try web.register(&r);
    try agent_tools.register(&r);
    try lua_tools.register(&r);
    return r;
}

pub fn openaiToolsJson(allocator: std.mem.Allocator, registry: Registry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[");
    for (registry.specs.items, 0..) |spec, i| {
        if (i != 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
        try appendJsonString(&out, allocator, spec.name);
        try out.appendSlice(allocator, ",\"description\":");
        try appendJsonString(&out, allocator, spec.description);
        try out.appendSlice(allocator, ",\"parameters\":");
        try out.appendSlice(allocator, spec.parameters_json);
        try out.appendSlice(allocator, "}}");
    }
    try out.appendSlice(allocator, "]");
    return out.toOwnedSlice(allocator);
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, s, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

test "registry rejects unknown tools" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    var ctx = Context{ .allocator = std.testing.allocator, .cwd = "/tmp", .home = "/tmp" };
    defer ctx.deinit();
    const parsed = try json.parse(std.testing.allocator, "{}");
    defer parsed.deinit();
    const out = try r.dispatch(&ctx, "nope", parsed.value);
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(out.is_error);
}
