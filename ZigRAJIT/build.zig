const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module
    const mod = b.addModule("ZigRAJIT", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Executable
    const exe = b.addExecutable(.{
        .name = "ZigRAJIT",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ZigRAJIT", .module = mod },
            },
        }),
    });
    exe.root_module.safety = false;          // отключаем safety для exe

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    // Tests for module
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.root_module.safety = false;    // отключаем safety для тестов модуля
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Tests for executable
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.root_module.safety = false;    // отключаем safety для тестов exe
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Test step
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
