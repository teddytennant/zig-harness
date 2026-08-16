const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zig-harness",
        .root_module = root,
    });
    linkDeps(b, exe);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run zig-harness");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    linkDeps(b, tests);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn linkDeps(b: *std.Build, step: *std.Build.Step.Compile) void {
    applyPkgConfig(b, step, "luajit");
    applyPkgConfig(b, step, "libcurl");
}

fn applyPkgConfig(b: *std.Build, step: *std.Build.Step.Compile, name: []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", "--cflags", "--libs", name },
    }) catch {
        // Fall back to common sonames so a non-Nix box still links.
        if (std.mem.eql(u8, name, "luajit")) {
            step.linkSystemLibrary("luajit-5.1");
        } else if (std.mem.eql(u8, name, "libcurl")) {
            step.linkSystemLibrary("curl");
        }
        return;
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        if (std.mem.eql(u8, name, "luajit")) {
            step.linkSystemLibrary("luajit-5.1");
        } else {
            step.linkSystemLibrary("curl");
        }
        return;
    }
    var it = std.mem.tokenizeAny(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), " \n");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            step.addIncludePath(.{ .cwd_relative = tok[2..] });
        } else if (std.mem.startsWith(u8, tok, "-L")) {
            step.addLibraryPath(.{ .cwd_relative = tok[2..] });
        } else if (std.mem.startsWith(u8, tok, "-l")) {
            step.linkSystemLibrary(tok[2..]);
        }
    }
}
