//! In-process LuaJIT host. Scripted tools and `run_code` run here.

const std = @import("std");
const c = @cImport({
    @cInclude("luajit-2.1/lua.h");
    @cInclude("luajit-2.1/lauxlib.h");
    @cInclude("luajit-2.1/lualib.h");
});

pub const Stdlib = enum { full, sandboxed };

pub const Result = struct {
    stdout: []u8,
    returned: ?[]u8,
    err: ?[]u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        if (self.returned) |r| allocator.free(r);
        if (self.err) |e| allocator.free(e);
    }

    pub fn text(self: Result, allocator: std.mem.Allocator) ![]u8 {
        if (self.err) |e| return allocator.dupe(u8, e);
        if (self.stdout.len > 0) return allocator.dupe(u8, self.stdout);
        if (self.returned) |r| return allocator.dupe(u8, r);
        return allocator.dupe(u8, "");
    }
};

const Host = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    printed: std.ArrayList(u8),
    stdlib: Stdlib,
    last_error: ?[]u8 = null,

    fn fail(self: *Host, L: ?*c.lua_State, msg: []const u8) c_int {
        if (self.last_error == null) {
            self.last_error = self.allocator.dupe(u8, msg) catch null;
        }
        c.lua_pushnil(L);
        return 1;
    }
};

fn lReadFile(L: ?*c.lua_State) callconv(.c) c_int {
    const host = hostOf(L);
    const path = c.luaL_checklstring(L, 1, null);
    const zpath = std.mem.span(path);
    const resolved = resolve(host, zpath) catch return host.fail(L, "cannot resolve path");
    defer host.allocator.free(resolved);
    const file = std.fs.openFileAbsolute(resolved, .{}) catch return host.fail(L, "cannot open file");
    defer file.close();
    const body = file.readToEndAlloc(host.allocator, 2 * 1024 * 1024) catch return host.fail(L, "cannot read file");
    defer host.allocator.free(body);
    c.lua_pushlstring(L, body.ptr, body.len);
    return 1;
}

fn lWriteFile(L: ?*c.lua_State) callconv(.c) c_int {
    const host = hostOf(L);
    const path = c.luaL_checklstring(L, 1, null);
    var len: usize = 0;
    const contents = c.luaL_checklstring(L, 2, &len);
    const zpath = std.mem.span(path);
    const resolved = resolve(host, zpath) catch return host.fail(L, "cannot resolve path");
    defer host.allocator.free(resolved);
    if (std.fs.path.dirname(resolved)) |dir| {
        std.fs.cwd().makePath(dir) catch return host.fail(L, "cannot create parent");
    }
    const file = std.fs.createFileAbsolute(resolved, .{ .truncate = true }) catch return host.fail(L, "cannot write file");
    defer file.close();
    file.writeAll(contents[0..len]) catch return host.fail(L, "cannot write file");
    return 0;
}

fn luaToString(L: ?*c.lua_State, idx: c_int, len: *usize) [*c]const u8 {
    if (truthy(c.lua_isstring(L, idx))) {
        return c.lua_tolstring(L, idx, len);
    }
    const t = c.lua_type(L, idx);
    if (t == c.LUA_TNUMBER) {
        const n = c.lua_tonumber(L, idx);
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{n}) catch "number";
        c.lua_pushstring(L, s.ptr);
        return c.lua_tolstring(L, -1, len);
    }
    const name: [:0]const u8 = if (t == c.LUA_TNIL)
        "nil"
    else if (t == c.LUA_TBOOLEAN)
        (if (truthy(c.lua_toboolean(L, idx))) "true" else "false")
    else
        "userdata";
    c.lua_pushstring(L, name.ptr);
    return c.lua_tolstring(L, -1, len);
}

fn truthy(v: anytype) bool {
    return switch (@TypeOf(v)) {
        bool => v,
        else => v != 0,
    };
}

fn lPrint(L: ?*c.lua_State) callconv(.c) c_int {
    const host = hostOf(L);
    const n = c.lua_gettop(L);
    var i: c_int = 1;
    while (i <= n) : (i += 1) {
        var len: usize = 0;
        const s = luaToString(L, i, &len);
        if (i > 1) host.printed.append(host.allocator, '\t') catch {};
        host.printed.appendSlice(host.allocator, s[0..len]) catch {};
    }
    host.printed.append(host.allocator, '\n') catch {};
    return 0;
}

fn hostOf(L: ?*c.lua_State) *Host {
    c.lua_getfield(L, c.LUA_REGISTRYINDEX, "zig_harness_host");
    const ptr = c.lua_touserdata(L, -1);
    c.lua_pop(L, 1);
    return @ptrCast(@alignCast(ptr));
}

fn resolve(host: *Host, path: []const u8) ![]u8 {
    if (host.stdlib == .sandboxed) {
        if (path.len > 0 and (path[0] == '/' or path[0] == '~')) return error.OutsideProject;
        if (std.mem.indexOf(u8, path, "..") != null) return error.OutsideProject;
        return std.fs.path.join(host.allocator, &.{ host.cwd, path });
    }
    if (path.len > 0 and path[0] == '/') return host.allocator.dupe(u8, path);
    return std.fs.path.join(host.allocator, &.{ host.cwd, path });
}

fn openLibs(L: ?*c.lua_State, stdlib: Stdlib) void {
    if (stdlib == .full) {
        c.luaL_openlibs(L);
        return;
    }
    // Sandbox: base + table + string + math. No io/os/package/debug.
    c.lua_pushcfunction(L, c.luaopen_base);
    c.lua_pushstring(L, "");
    c.lua_call(L, 1, 0);
    c.lua_pushcfunction(L, c.luaopen_table);
    c.lua_pushstring(L, "table");
    c.lua_call(L, 1, 0);
    c.lua_pushcfunction(L, c.luaopen_string);
    c.lua_pushstring(L, "string");
    c.lua_call(L, 1, 0);
    c.lua_pushcfunction(L, c.luaopen_math);
    c.lua_pushstring(L, "math");
    c.lua_call(L, 1, 0);
}

fn installWizard(L: ?*c.lua_State) void {
    c.lua_newtable(L);
    c.lua_pushcfunction(L, lReadFile);
    c.lua_setfield(L, -2, "read_file");
    c.lua_pushcfunction(L, lWriteFile);
    c.lua_setfield(L, -2, "write_file");
    c.lua_pushstring(L, "luajit");
    c.lua_setfield(L, -2, "runtime");
    c.lua_setglobal(L, "wizard");
    c.lua_pushcfunction(L, lPrint);
    c.lua_setglobal(L, "print");
}

fn pushJsonValue(L: ?*c.lua_State, v: std.json.Value) void {
    switch (v) {
        .null => c.lua_pushnil(L),
        .bool => |b| c.lua_pushboolean(L, if (b) 1 else 0),
        .integer => |n| c.lua_pushnumber(L, @floatFromInt(n)),
        .float => |f| c.lua_pushnumber(L, f),
        .number_string => |s| {
            const n = std.fmt.parseFloat(f64, s) catch 0;
            c.lua_pushnumber(L, n);
        },
        .string => |s| c.lua_pushlstring(L, s.ptr, s.len),
        .array => |a| {
            c.lua_createtable(L, @intCast(a.items.len), 0);
            for (a.items, 0..) |item, i| {
                pushJsonValue(L, item);
                c.lua_rawseti(L, -2, @intCast(i + 1));
            }
        },
        .object => |o| {
            c.lua_createtable(L, 0, @intCast(o.count()));
            var it = o.iterator();
            while (it.next()) |entry| {
                pushJsonValue(L, entry.value_ptr.*);
                c.lua_pushlstring(L, entry.key_ptr.*.ptr, entry.key_ptr.*.len);
                // stack: table, value, key  -> need key then value
                c.lua_insert(L, -2);
                c.lua_settable(L, -3);
            }
        },
    }
}

pub fn run(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    source: []const u8,
    args_json: ?std.json.Value,
    stdlib: Stdlib,
) !Result {
    const L = c.luaL_newstate() orelse return error.LuaState;
    defer c.lua_close(L);

    var host = Host{
        .allocator = allocator,
        .cwd = cwd,
        .printed = .empty,
        .stdlib = stdlib,
    };
    defer host.printed.deinit(allocator);

    c.lua_pushlightuserdata(L, &host);
    c.lua_setfield(L, c.LUA_REGISTRYINDEX, "zig_harness_host");

    openLibs(L, stdlib);
    installWizard(L);

    if (args_json) |v| {
        pushJsonValue(L, v);
    } else {
        c.lua_newtable(L);
    }
    c.lua_setglobal(L, "args");

    const cwd_z = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_z);
    c.lua_pushstring(L, cwd_z.ptr);
    c.lua_setglobal(L, "cwd");

    const src_z = try allocator.dupeZ(u8, source);
    defer allocator.free(src_z);

    var err_text: ?[]u8 = null;
    var returned: ?[]u8 = null;

    if (c.luaL_loadstring(L, src_z.ptr) != 0) {
        const msg = std.mem.span(c.lua_tolstring(L, -1, null));
        err_text = try allocator.dupe(u8, msg);
    } else if (c.lua_pcall(L, 0, 1, 0) != 0) {
        const msg = std.mem.span(c.lua_tolstring(L, -1, null));
        err_text = try std.fmt.allocPrint(allocator, "error: {s}", .{msg});
    } else if (host.last_error) |e| {
        err_text = e;
        host.last_error = null;
    } else if (!truthy(c.lua_isnil(L, -1))) {
        var len: usize = 0;
        const s = luaToString(L, -1, &len);
        returned = try allocator.dupe(u8, s[0..len]);
    }

    if (host.last_error) |e| allocator.free(e);

    return .{
        .stdout = try allocator.dupe(u8, host.printed.items),
        .returned = returned,
        .err = err_text,
    };
}

test "luajit prints and returns" {
    const r = try run(std.testing.allocator, "/tmp", "print('hi')\nreturn 2+2", null, .full);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.err == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "hi") != null);
    try std.testing.expectEqualStrings("4", r.returned.?);
}

test "sandboxed script cannot climb out" {
    const r = try run(
        std.testing.allocator,
        "/tmp",
        "return wizard.read_file('/etc/passwd')",
        null,
        .sandboxed,
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.err != null);
}
