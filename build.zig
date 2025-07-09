const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

 

    // Create the main CBOR library module
    const cbor_mod = b.addModule("cbor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build static library
    const lib = b.addLibrary(.{
        .name = "cbor",
        .root_module = cbor_mod,
    });
    b.installArtifact(lib);

    
    const exe = b.addExecutable(.{
        .name = "cbor",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("cbor_lib", cbor_mod);
    b.installArtifact(exe);

    // Run command for the demo executable
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the demo app");
    run_step.dependOn(&run_cmd.step);


    const lib_unit_tests = b.addTest(.{
        .name = "cbor-lib-tests",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Demo executable tests
    const exe_unit_tests = b.addTest(.{
        .name = "cbor-exe-tests",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("cbor_lib", cbor_mod);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Comprehensive CBOR tests
    const cbor_tests = b.addTest(.{
        .name = "cbor-tests",
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_cbor_tests = b.addRunArtifact(cbor_tests);

    // Test steps
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_cbor_tests.step);

    const cbor_test_step = b.step("test-cbor", "Run comprehensive CBOR tests");
    cbor_test_step.dependOn(&run_cbor_tests.step);

    // =============================================================================
    // BENCHMARK CONFIGURATION
    // =============================================================================

    // Delegate benchmark commands to the dedicated bench/zig directory
    const bench_step = b.step("bench", "Run benchmarks from bench/zig directory");
    const bench_run = b.addSystemCommand(&[_][]const u8{ "zig", "build", "run" });
    bench_run.setCwd(b.path("bench/zig"));
    bench_step.dependOn(&bench_run.step);

    const release_bench_step = b.step("release-bench", "Run optimized benchmarks from bench/zig directory");
    const release_bench_run = b.addSystemCommand(&[_][]const u8{ "zig", "build", "release-bench" });
    release_bench_run.setCwd(b.path("bench/zig"));
    release_bench_step.dependOn(&release_bench_run.step);
}
