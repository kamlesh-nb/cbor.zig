const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module for external consumption
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Make the module available for other projects to depend on
    _ = b.addModule("cbor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("cbor_lib", lib_mod);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cbor",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    // Optional: Build and install examples/demo executable
    const exe = b.addExecutable(.{
        .name = "cbor",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Run command for the demo executable
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the demo app");
    run_step.dependOn(&run_cmd.step);

  
    // Test configuration
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Dedicated test suite
    const dedicated_tests = b.addTest(.{
        .name = "cbor-tests",
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_dedicated_tests = b.addRunArtifact(dedicated_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_dedicated_tests.step);
}
