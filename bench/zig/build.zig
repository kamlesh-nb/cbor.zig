const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create a module for the CBOR library (from parent directory)
    const cbor_mod = b.createModule(.{
        .root_source_file = b.path("../../src/cbor.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main benchmark executable
    const benchmark = b.addExecutable(.{
        .name = "zbor_benchmark",
        .root_source_file = b.path("bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the CBOR module import
    benchmark.root_module.addImport("cbor", cbor_mod);

    b.installArtifact(benchmark);

    // Run command for the benchmark
    const run_cmd = b.addRunArtifact(benchmark);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the ZBOR comprehensive benchmark");
    run_step.dependOn(&run_cmd.step);

    // Individual benchmark steps
    const bench_step = b.step("bench", "Run comprehensive ZBOR benchmarks");
    bench_step.dependOn(&run_cmd.step);

    const integer_bench_step = b.step("integer-bench", "Run integer encoding/decoding benchmarks");
    integer_bench_step.dependOn(&run_cmd.step);

    // Performance profiling step
    const profile_step = b.step("profile", "Run benchmarks with profiling enabled");
    profile_step.dependOn(&run_cmd.step);

    // Release mode benchmarks for production testing
    const release_benchmark = b.addExecutable(.{
        .name = "zbor_benchmark_release",
        .root_source_file = b.path("bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    release_benchmark.root_module.addImport("cbor", cbor_mod);
    b.installArtifact(release_benchmark);

    const run_release_cmd = b.addRunArtifact(release_benchmark);
    run_release_cmd.step.dependOn(b.getInstallStep());

    const release_bench_step = b.step("release-bench", "Run optimized release benchmarks");
    release_bench_step.dependOn(&run_release_cmd.step);
}
