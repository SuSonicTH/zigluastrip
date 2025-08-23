const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigLuaStrip = b.addModule("zigLuaStrip", .{
        .root_source_file = b.path("src/luastrip.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "zigluastrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    exe.root_module.addImport("zigLuaStrip", zigLuaStrip);
    const exe_artifact = b.addInstallArtifact(exe, .{});

    const exe_step = b.step("exe", "build the zigluastrip executeable");
    exe_step.dependOn(&exe_artifact.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
}
