const std = @import("std");

pub fn build(b: *std.Build) void {
    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }),
    };

    const exe = b.addExecutable(.{
        .name = "github-checks-stats",
        .root_source_file = std.Build.LazyPath.relative("src/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    b.installArtifact(exe);
    configureModule(b, &exe.root_module, opts);

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
            .root_source_file = exe.root_module.root_source_file.?,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureModule(b, &exe_test.root_module, opts);

        const run_cizero_exe_test = b.addRunArtifact(exe_test);
        test_step.dependOn(&run_cizero_exe_test.step);
    }
}

fn configureModule(b: *std.Build, module: *std.Build.Module, opts: anytype) void {
    module.addImport("args", b.dependency("args", opts).module("args"));
}
