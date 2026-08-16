const std = @import("std");
const agent = @import("agent.zig");
const config_mod = @import("config.zig");
const json = @import("json.zig");
const lua = @import("lua.zig");
const prompts = @import("prompts.zig");
const tools = @import("tools/mod.zig");
const util = @import("util.zig");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

const usage =
    \\zig-harness — a stripped-down Wizard in Zig + LuaJIT
    \\
    \\Usage:
    \\  zig-harness -p <prompt> [options]
    \\  zig-harness --prompt <prompt>
    \\  zig-harness --eval-lua <code>
    \\  zig-harness --help
    \\  zig-harness --version
    \\
    \\Options:
    \\  -p, --prompt <text>   Task to run (headless)
    \\  --mode genie|sovereign
    \\  --plan                Start in plan mode
    \\  --omakase             Chef's-choice plan mode
    \\  --max-steps <n>       Cap tool-calling rounds (0 = default 64)
    \\  --cwd <path>          Project root (default: current directory)
    \\  --eval-lua <code>     Run a LuaJIT snippet and exit (no model)
    \\
    \\Env:
    \\  OPENAI_API_KEY            Bearer token
    \\  ZIG_HARNESS_MODEL         Model id (default gpt-4.1-mini)
    \\  ZIG_HARNESS_BASE_URL      OpenAI-compatible root (default https://api.openai.com/v1)
    \\  ZIG_HARNESS_API_KEY_ENV   Name of the env var holding the key
    \\  ZIG_HARNESS_HOME          Config/memory dir (default ~/.zig-harness)
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var prompt: ?[]const u8 = null;
    var mode: config_mod.Mode = .genie;
    var plan = false;
    var omakase = false;
    var max_steps: u32 = 0;
    var cwd_arg: ?[]const u8 = null;
    var eval_lua: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, a, "--version")) {
            try std.fs.File.stdout().writeAll("zig-harness 0.1.0\n");
            return;
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--prompt")) {
            i += 1;
            if (i >= args.len) return fail("--prompt needs a value");
            prompt = args[i];
        } else if (std.mem.eql(u8, a, "--mode")) {
            i += 1;
            if (i >= args.len) return fail("--mode needs a value");
            if (std.mem.eql(u8, args[i], "sovereign")) {
                mode = .sovereign;
            } else if (std.mem.eql(u8, args[i], "genie")) {
                mode = .genie;
            } else return fail("--mode must be genie or sovereign");
        } else if (std.mem.eql(u8, a, "--plan")) {
            plan = true;
        } else if (std.mem.eql(u8, a, "--omakase")) {
            omakase = true;
            plan = true;
        } else if (std.mem.eql(u8, a, "--max-steps")) {
            i += 1;
            if (i >= args.len) return fail("--max-steps needs a value");
            max_steps = std.fmt.parseInt(u32, args[i], 10) catch return fail("bad --max-steps");
        } else if (std.mem.eql(u8, a, "--cwd")) {
            i += 1;
            if (i >= args.len) return fail("--cwd needs a value");
            cwd_arg = args[i];
        } else if (std.mem.eql(u8, a, "--eval-lua")) {
            i += 1;
            if (i >= args.len) return fail("--eval-lua needs a value");
            eval_lua = args[i];
        } else if (a.len > 0 and a[0] == '-') {
            return fail("unknown flag");
        } else if (prompt == null) {
            prompt = a;
        }
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = cwd_arg orelse try std.posix.getcwd(&cwd_buf);

    if (eval_lua) |code| {
        const result = try lua.run(allocator, cwd, code, null, .full);
        defer result.deinit(allocator);
        const text = try result.text(allocator);
        defer allocator.free(text);
        try std.fs.File.stdout().writeAll(text);
        if (text.len == 0 or text[text.len - 1] != '\n') try std.fs.File.stdout().writeAll("\n");
        if (result.err != null) std.process.exit(1);
        return;
    }

    const user_prompt = prompt orelse {
        try std.fs.File.stdout().writeAll(usage);
        std.process.exit(2);
    };

    var cfg = try config_mod.load(allocator, cwd);
    defer cfg.deinit();
    cfg.mode = mode;
    cfg.plan_mode = plan;
    cfg.omakase = omakase;
    cfg.max_steps = max_steps;

    const code = try agent.run(allocator, &cfg, .{
        .prompt = user_prompt,
        .max_steps = max_steps,
        .plan_mode = plan,
        .omakase = omakase,
    });
    std.process.exit(code);
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("error: {s}\n{s}", .{ msg, usage });
    std.process.exit(2);
}

test {
    _ = json;
    _ = util;
    _ = config_mod;
    _ = prompts;
    _ = tools;
    _ = lua;
    _ = @import("tools/file.zig");
    _ = @import("tools/shell.zig");
    _ = @import("tools/git.zig");
    _ = @import("tools/memory.zig");
    _ = @import("tools/todo.zig");
    _ = @import("tools/manual.zig");
    _ = @import("tools/web.zig");
    _ = @import("tools/agent_tools.zig");
    _ = @import("tools/lua_tools.zig");
}
