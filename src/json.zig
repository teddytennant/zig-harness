//! Thin helpers around std.json for tool arguments and the OpenAI wire format.

const std = @import("std");

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;
pub const Array = std.json.Array;

pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, allocator, raw, .{
        .allocate = .alloc_always,
    });
}

pub fn stringify(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn objectGet(obj: Value, key: []const u8) ?Value {
    if (obj != .object) return null;
    return obj.object.get(key);
}

pub fn getString(obj: Value, key: []const u8) ?[]const u8 {
    const v = objectGet(obj, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn getBool(obj: Value, key: []const u8) ?bool {
    const v = objectGet(obj, key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getInt(obj: Value, key: []const u8) ?i64 {
    const v = objectGet(obj, key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn getUsize(obj: Value, key: []const u8) ?usize {
    const n = getInt(obj, key) orelse return null;
    if (n < 0) return null;
    return @intCast(n);
}

pub fn emptyObject(allocator: std.mem.Allocator) Value {
    return .{ .object = ObjectMap.init(allocator) };
}

pub fn objectPut(obj: *Value, key: []const u8, value: Value) !void {
    try obj.object.put(key, value);
}

test "parse object and read fields" {
    const parsed = try parse(std.testing.allocator, "{\"path\":\"a.txt\",\"n\":3,\"ok\":true}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a.txt", getString(parsed.value, "path").?);
    try std.testing.expectEqual(@as(i64, 3), getInt(parsed.value, "n").?);
    try std.testing.expect(getBool(parsed.value, "ok").?);
}
