const std = @import("std");

pub fn build(b: *std.Build) void {
    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }),
    };

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    mod.addImport("args", b.dependency("args", opts).module("args"));
    mod.addImport("zeit", b.dependency("zeit", opts).module("zeit"));

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
}
