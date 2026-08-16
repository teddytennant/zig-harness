const std = @import("std");
const util = @import("util.zig");

pub const Mode = enum { genie, sovereign };

pub const ProviderKind = enum { openai, anthropic };

pub const Provider = struct {
    name: []const u8,
    kind: ProviderKind,
    base_url: []const u8,
    model: []const u8,
    api_key_env: []const u8,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    mode: Mode = .genie,
    max_steps: u32 = 0,
    plan_mode: bool = false,
    omakase: bool = false,
    cwd: []const u8,
    home: []const u8,
    active_provider: []const u8,
    providers: []Provider,
    owned: bool = false,

    pub fn deinit(self: *Config) void {
        if (!self.owned) return;
        self.allocator.free(self.cwd);
        self.allocator.free(self.home);
        self.allocator.free(self.active_provider);
        for (self.providers) |p| {
            self.allocator.free(p.base_url);
            self.allocator.free(p.model);
            self.allocator.free(p.api_key_env);
        }
        self.allocator.free(self.providers);
    }

    pub fn active(self: Config) ?Provider {
        for (self.providers) |p| {
            if (std.mem.eql(u8, p.name, self.active_provider)) return p;
        }
        if (self.providers.len > 0) return self.providers[0];
        return null;
    }
};

pub fn load(allocator: std.mem.Allocator, cwd: []const u8) !Config {
    const home = try util.harnessHome(allocator);
    errdefer allocator.free(home);

    var providers = try allocator.alloc(Provider, 1);
    errdefer allocator.free(providers);

    const model = std.posix.getenv("ZIG_HARNESS_MODEL") orelse
        std.posix.getenv("OPENAI_MODEL") orelse "gpt-4.1-mini";
    const base = std.posix.getenv("ZIG_HARNESS_BASE_URL") orelse
        std.posix.getenv("OPENAI_BASE_URL") orelse "https://api.openai.com/v1";
    const key_env = std.posix.getenv("ZIG_HARNESS_API_KEY_ENV") orelse "OPENAI_API_KEY";

    providers[0] = .{
        .name = "openai",
        .kind = .openai,
        .base_url = try allocator.dupe(u8, base),
        .model = try allocator.dupe(u8, model),
        .api_key_env = try allocator.dupe(u8, key_env),
    };

    return .{
        .allocator = allocator,
        .cwd = try allocator.dupe(u8, cwd),
        .home = home,
        .active_provider = try allocator.dupe(u8, "openai"),
        .providers = providers,
        .owned = true,
    };
}

test "load synthesizes an openai provider" {
    var cfg = try load(std.testing.allocator, "/tmp");
    defer cfg.deinit();
    try std.testing.expect(cfg.active() != null);
    try std.testing.expectEqual(Mode.genie, cfg.mode);
}
