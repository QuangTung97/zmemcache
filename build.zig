const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_tsan = b.option(
        bool,
        "tsan",
        "Enable thread sanitizer",
    ) orelse false;

    const zutil_mod = b.addModule("zutil", .{
        .root_source_file = b.path("src/util/root.zig"),
        .target = target,
        .sanitize_thread = enable_tsan,
    });

    const zcore_mod = b.addModule("zcore", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zutil", .module = zutil_mod },
        },
        .sanitize_thread = enable_tsan,
    });

    const wiring_mod = b.addModule("wiring", .{
        .root_source_file = b.path("src/wiring/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zcore", .module = zcore_mod },
        },
        .sanitize_thread = enable_tsan,
    });

    const exe = b.addExecutable(.{
        .name = "zmemcache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcore", .module = zcore_mod },
            },
            .sanitize_thread = enable_tsan,
        }),
        .use_llvm = enable_tsan,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    addTestModule(b, test_step, zcore_mod, enable_tsan);
    addTestModule(b, test_step, zutil_mod, enable_tsan);
    addTestModule(b, test_step, wiring_mod, enable_tsan);
}

fn addTestModule(b: *std.Build, test_step: *std.Build.Step, mod: *std.Build.Module, enable_tsan: bool) void {
    const run_tests = b.addRunArtifact(
        b.addTest(.{
            .root_module = mod,
            .use_llvm = enable_tsan,
        }),
    );

    test_step.dependOn(
        &run_tests.step,
    );
}
