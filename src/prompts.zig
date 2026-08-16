//! System prompts and the on-demand charter manual.
//! Personality text is copied from Wizard; paths name ~/.zig-harness.

const std = @import("std");
const config = @import("config.zig");
const memory = @import("tools/memory.zig");

pub const genie = @embedFile("embedded/genie.md");
pub const sovereign = @embedFile("embedded/sovereign.md");
pub const plan = @embedFile("embedded/plan.md");
pub const omakase = @embedFile("embedded/omakase.md");
pub const todo = @embedFile("embedded/todo.md");
pub const context = @embedFile("embedded/context.md");
pub const charter = @embedFile("embedded/WIZARD.md");

const memory_rules =
    \\Every memory has a type:
    \\- `user` — who they are: their role, expertise, and standing preferences.
    \\- `feedback` — how you should work: corrections *and* confirmed approaches. Include the why, not just the what.
    \\- `project` — ongoing work, goals, and constraints that are not derivable from the code or the git history. Convert relative dates ("next week") to absolute ones.
    \\- `reference` — a pointer to an external resource: a URL, a dashboard, a ticket.
    \\
    \\Link related memories from a memory's body by name, `[[wiki-style]]`. A link to a memory that does not exist yet is fine — it marks something worth writing later, not an error. A `read` tells you which links resolve.
    \\
    \\A memory has to earn its place:
    \\- Never save what the repo already records: code structure, past fixes, anything in the git history. Never save what only matters to the current conversation.
    \\- Before saving, look for a memory that already covers the same ground and update it (save over its name) instead of creating a near-duplicate.
    \\- Delete a memory that turns out to be wrong. Names are kebab-case; descriptions are one line.
;

const memory_essentials =
    \\Types: `user` (who they are), `feedback` (how you should work, with the why), `project` (goals and constraints not derivable from the code; convert relative dates to absolute), `reference` (a URL, dashboard, or ticket). Link related memories from a body by name, `[[wiki-style]]`. Before you save or delete, read `manual` topic `memory`: it says what earns a place and what must never be written down.
;

const charter_digest_lead =
    \\Your operating charter (`WIZARD.md`) is bundled in this binary. What follows is its index, not its text: to read a section in full, call the `manual` tool with one of the topic ids below. Read the section before you act on its subject rather than guessing what it says.
;

const charter_always_on =
    \\In force on every reply, never worth a lookup:
    \\- No em dashes in anything you write (replies, code, commits, docs). Use a comma, colon, period, parentheses, or a plain hyphen.
    \\- Never fabricate success. Claim a build, test, install, fork, or publish only when you ran it and saw the result.
    \\- Gates stay. Do not route around deep evolve's build and smoke gate, or plan mode's read-only phase.
    \\- Write like a person: concise, plain, no AI-slop prose and no academic padding. The full rules are `manual` topic `writing`.
;

pub const Page = struct {
    id: []const u8,
    title: []const u8,
    body: []const u8,
};

pub fn pages() []const Page {
    return compiled_pages;
}

var compiled_pages: []const Page = &.{};

var pages_once = std.once(initPages);
var pages_storage: std.ArrayList(Page) = undefined;
var pages_arena: std.heap.ArenaAllocator = undefined;

fn initPages() void {
    pages_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = pages_arena.allocator();
    pages_storage = .empty;
    parseCharter(alloc) catch return;
    pages_storage.append(alloc, .{
        .id = "memory",
        .title = "Memory: what earns a place",
        .body = memory_rules,
    }) catch return;
    compiled_pages = pages_storage.items;
}

fn parseCharter(alloc: std.mem.Allocator) !void {
    var title: []const u8 = "Overview";
    var body_start: usize = 0;
    var i: usize = 0;
    const text = charter;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = text[i..nl];
        if (std.mem.startsWith(u8, line, "## ")) {
            try pushPage(alloc, title, std.mem.trim(u8, text[body_start..i], "\n"));
            title = std.mem.trim(u8, line[3..], " \t");
            body_start = if (nl < text.len) nl + 1 else text.len;
        }
        i = if (nl < text.len) nl + 1 else text.len;
    }
    try pushPage(alloc, title, std.mem.trim(u8, text[body_start..], "\n"));
}

fn pushPage(alloc: std.mem.Allocator, title: []const u8, body: []const u8) !void {
    if (body.len == 0) return;
    const id = try topicId(alloc, title);
    try pages_storage.append(alloc, .{ .id = id, .title = title, .body = body });
}

fn topicId(alloc: std.mem.Allocator, title: []const u8) ![]u8 {
    const rest = blk: {
        if (std.mem.indexOf(u8, title, ". ")) |dot| {
            const num = title[0..dot];
            var all_digits = num.len > 0;
            for (num) |ch| {
                if (ch < '0' or ch > '9') all_digits = false;
            }
            if (all_digits) break :blk title[dot + 2 ..];
        }
        break :blk title;
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var words: usize = 0;
    var i: usize = 0;
    while (i < rest.len and words < 3) {
        while (i < rest.len and !std.ascii.isAlphanumeric(rest[i])) i += 1;
        const start = i;
        while (i < rest.len and std.ascii.isAlphanumeric(rest[i])) i += 1;
        if (start == i) break;
        if (words > 0) try out.append(alloc, '-');
        var j = start;
        while (j < i) : (j += 1) try out.append(alloc, std.ascii.toLower(rest[j]));
        words += 1;
    }
    if (out.items.len == 0) try out.appendSlice(alloc, "untitled");
    return out.toOwnedSlice(alloc);
}

pub fn lookup(topic: []const u8) ?Page {
    pages_once.call();
    var buf: [64]u8 = undefined;
    const n = @min(topic.len, buf.len);
    @memcpy(buf[0..n], topic[0..n]);
    const needle_raw = std.mem.trim(u8, buf[0..n], " \t");
    const needle = blk: {
        if (needle_raw.len > 0 and needle_raw[0] == 0xc2) break :blk needle_raw; // leave unicode alone
        var t = needle_raw;
        if (t.len > 0 and t[0] == 0xc2) t = t; // no-op, keep simple
        // strip leading section sign-like prefixes and spaces
        while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) t = t[1..];
        break :blk t;
    };
    var lower_buf: [64]u8 = undefined;
    const ln = @min(needle.len, lower_buf.len);
    var k: usize = 0;
    while (k < ln) : (k += 1) lower_buf[k] = std.ascii.toLower(needle[k]);
    const needle_l = lower_buf[0..ln];

    for (compiled_pages) |p| {
        if (std.mem.eql(u8, p.id, needle_l)) return p;
    }
    for (compiled_pages) |p| {
        if (sectionNumber(p.title)) |num| {
            if (std.mem.eql(u8, num, needle_l)) return p;
        }
    }
    for (compiled_pages) |p| {
        if (std.mem.startsWith(u8, p.id, needle_l)) return p;
        var title_buf: [96]u8 = undefined;
        const tn = @min(p.title.len, title_buf.len);
        var ti: usize = 0;
        while (ti < tn) : (ti += 1) title_buf[ti] = std.ascii.toLower(p.title[ti]);
        if (std.mem.indexOf(u8, title_buf[0..tn], needle_l) != null) return p;
    }
    return null;
}

fn sectionNumber(title: []const u8) ?[]const u8 {
    const dot = std.mem.indexOf(u8, title, ". ") orelse return null;
    const num = title[0..dot];
    if (num.len == 0) return null;
    for (num) |ch| {
        if (ch < '0' or ch > '9') return null;
    }
    return num;
}

pub fn listTopics(allocator: std.mem.Allocator) ![]u8 {
    pages_once.call();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Topics:\n");
    for (compiled_pages) |p| {
        try out.writer(allocator).print("- `{s}` ({s})\n", .{ p.id, p.title });
    }
    return out.toOwnedSlice(allocator);
}

fn charterDigest(allocator: std.mem.Allocator) ![]u8 {
    pages_once.call();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "## Wizard charter (WIZARD.md)\n\n");
    try out.appendSlice(allocator, charter_digest_lead);
    try out.appendSlice(allocator, "\n\n");
    try out.appendSlice(allocator, "Capability ladder. A task that needs a capability you lack is work, not a refusal: acquire it, and refuse only after trying and hitting a hard wall. Climb cheapest rung first and pick the lowest that solves it: 1. Skill, 2. MCP server, 3. Scripted tool, 4. Subagent, 5. Deep evolve (`deep=true`). What each rung costs: `manual` topic `prime-directive-build`. The recipe for browser use: `manual` topic `recipe-browser-use`.\n\n");
    try out.appendSlice(allocator, "Topics: ");
    for (compiled_pages, 0..) |p, i| {
        if (i != 0) try out.appendSlice(allocator, "; ");
        try out.writer(allocator).print("`{s}` ({s})", .{ p.id, p.title });
    }
    try out.appendSlice(allocator, ".\n\n");
    try out.appendSlice(allocator, charter_always_on);
    return out.toOwnedSlice(allocator);
}

fn environmentSection(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\## Environment
        \\
        \\- Shell: `sh`. Command lines from `execute` are parsed by this shell, so write syntax it accepts.
        \\- OS: {s} ({s}).
        \\
    , .{ @tagName(@import("builtin").os.tag), @tagName(@import("builtin").cpu.arch) });
}

pub fn buildSystemPrompt(allocator: std.mem.Allocator, cfg: config.Config) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const base = switch (cfg.mode) {
        .genie => genie,
        .sovereign => sovereign,
    };
    try out.appendSlice(allocator, std.mem.trim(u8, base, "\n"));
    try out.appendSlice(allocator, "\n\n");

    const digest = try charterDigest(allocator);
    defer allocator.free(digest);
    try out.appendSlice(allocator, digest);
    try out.appendSlice(allocator, "\n\n");

    const env = try environmentSection(allocator);
    defer allocator.free(env);
    try out.appendSlice(allocator, env);
    try out.appendSlice(allocator, "\n");

    try out.appendSlice(allocator, todo);
    try out.appendSlice(allocator, "\n\n");
    try out.appendSlice(allocator, context);
    try out.appendSlice(allocator, "\n\n");

    if (cfg.plan_mode) {
        try out.appendSlice(allocator, plan);
        try out.appendSlice(allocator, "\n\n");
        if (cfg.omakase) {
            try out.appendSlice(allocator, omakase);
            try out.appendSlice(allocator, "\n\n");
        }
    }

    const idx = try memory.indexMarkdown(allocator, cfg.home, cfg.cwd);
    defer allocator.free(idx);
    if (idx.len == 0) {
        try out.appendSlice(allocator, "You have persistent project memory via the `memory` tool, but nothing is saved for this project yet. When you learn a durable fact, record it with action \"save\": it appears in your system prompt next session, so the memory you write now is the one you read then.\n\n");
    } else {
        try out.appendSlice(allocator, "You have persistent project memory. The index below lists every saved memory.\n\n");
        try out.appendSlice(allocator, idx);
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, memory_essentials);
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

test "lookup finds charter sections" {
    try std.testing.expect(lookup("writing") != null);
    try std.testing.expect(lookup("memory") != null);
    try std.testing.expect(lookup("7") != null);
    try std.testing.expect(lookup("no-such-topic") == null);
}

test "system prompt contains always-on rules" {
    var cfg = try config.load(std.testing.allocator, "/tmp");
    defer cfg.deinit();
    const p = try buildSystemPrompt(std.testing.allocator, cfg);
    defer std.testing.allocator.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "No em dashes") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "manual") != null);
}
