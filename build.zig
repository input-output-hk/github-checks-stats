const std = @import("std");
const utils = @import("utils").utils;

pub fn build(b: *std.Build) void {
    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }),
    };

    const translate_c_mod = translate_c_mod: {
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.path("src/c.h"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        utils.addNixIncludePaths(translate_c, b.graph.environ_map) catch |err| @panic(@errorName(err));
        break :translate_c_mod translate_c.createModule();
    };
    translate_c_mod.linkSystemLibrary("sqlite3", .{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "c", .module = translate_c_mod },
            .{ .name = "args", .module = b.dependency("args", opts).module("args") },
            .{ .name = "metrics", .module = b.dependency("metrics", opts).module("metrics") },
            .{ .name = "utils", .module = b.dependency("utils", opts).module("utils") },
            .{ .name = "zeit", .module = b.dependency("zeit", opts).module("zeit") },
            .{ .name = "zqlite", .module = b.dependency("zqlite", opts).module("zqlite") },
            .{ .name = "zqlite-typed", .module = b.dependency("zqlite_typed", opts).module("zqlite-typed") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "github-checks-stats",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    {
        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_exe.addArgs(args);

        run_step.dependOn(&run_exe.step);
    }

    const test_step = b.step("test", "Run unit tests");
    {
        const exe_test = b.addTest(.{
            .name = "exe",
            .root_module = mod,
        });

        const run_exe_test = b.addRunArtifact(exe_test);
        test_step.dependOn(&run_exe_test.step);
    }

    _ = utils.addCheckTls(b);
}
