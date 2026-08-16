const std = @import("std");

pub const max_output_bytes: usize = 64 * 1024;
pub const max_read_lines: usize = 2_000;
pub const max_list_entries: usize = 500;
pub const default_timeout_secs: u64 = 120;
pub const max_timeout_secs: u64 = 600;

pub fn homeDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("HOME")) |h| return allocator.dupe(u8, h);
    return error.NoHome;
}

pub fn harnessHome(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("ZIG_HARNESS_HOME")) |h| return allocator.dupe(u8, h);
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".zig-harness" });
}

pub fn expandUser(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '~') {
        const home = try homeDir(allocator);
        defer allocator.free(home);
        if (path.len == 1) return allocator.dupe(u8, home);
        if (path[1] == '/') {
            return std.fs.path.join(allocator, &.{ home, path[2..] });
        }
    }
    return allocator.dupe(u8, path);
}

/// Resolve `path` against `cwd`. Absolute paths and `~` are accepted.
pub fn resolvePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    const expanded = try expandUser(allocator, path);
    defer allocator.free(expanded);
    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);
    return std.fs.path.join(allocator, &.{ cwd, expanded });
}

pub fn truncate(allocator: std.mem.Allocator, text: []const u8, cap: usize) ![]u8 {
    if (text.len <= cap) return allocator.dupe(u8, text);
    const suffix = "\n... [truncated]";
    const keep = if (cap > suffix.len) cap - suffix.len else cap;
    var out = try allocator.alloc(u8, keep + suffix.len);
    @memcpy(out[0..keep], text[0..keep]);
    @memcpy(out[keep..], suffix);
    return out;
}

pub fn kebabOk(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return name[0] != '-' and name[name.len - 1] != '-';
}

test "resolvePath joins relative" {
    const p = try resolvePath(std.testing.allocator, "/tmp/proj", "src/main.zig");
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("/tmp/proj/src/main.zig", p);
}

test "kebabOk" {
    try std.testing.expect(kebabOk("user-name"));
    try std.testing.expect(!kebabOk("User"));
    try std.testing.expect(!kebabOk("-x"));
}
