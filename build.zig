const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lmdb_dep = b.dependency("zig-lmdb", .{});
    const lmdb = lmdb_dep.module("lmdb");

    const cli_dep = b.dependency("zig-cli", .{});

    const okra = b.addModule("okra", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    okra.addImport("lmdb", lmdb);

    {
        // CLI
        const cli = b.addExecutable(.{
            .name = "okra",
            .root_source_file = b.path("./cli/main.zig"),
            .optimize = optimize,
            .target = target,
        });

        cli.root_module.addImport("lmdb", lmdb);
        cli.root_module.addImport("okra", okra);
        cli.root_module.addImport("zig-cli", cli_dep.module("zig-cli"));

        cli.linkLibC();
        b.installArtifact(cli);

        const cli_artifact = b.addInstallArtifact(cli, .{});
        b.step("cli", "Build the CLI").dependOn(&cli_artifact.step);
    }

    {
        // Tests
        const header_tests = b.addTest(.{ .root_source_file = b.path("src/header_test.zig") });
        header_tests.root_module.addImport("lmdb", lmdb);
        const header_test_artifact = b.addRunArtifact(header_tests);
        b.step("test-header", "Run Header tests").dependOn(&header_test_artifact.step);

        const builder_tests = b.addTest(.{ .root_source_file = b.path("src/builder_test.zig") });
        builder_tests.root_module.addImport("lmdb", lmdb);
        const builder_test_artifact = b.addRunArtifact(builder_tests);
        b.step("test-builder", "Run Builder tests").dependOn(&builder_test_artifact.step);

        const cursor_tests = b.addTest(.{ .root_source_file = b.path("src/cursor_test.zig") });
        cursor_tests.root_module.addImport("lmdb", lmdb);
        const cursor_test_artifact = b.addRunArtifact(cursor_tests);
        b.step("test-cursor", "Run Cursor tests").dependOn(&cursor_test_artifact.step);

        const tree_tests = b.addTest(.{ .root_source_file = b.path("src/tree_test.zig") });
        tree_tests.root_module.addImport("lmdb", lmdb);
        const tree_test_artifact = b.addRunArtifact(tree_tests);
        b.step("test-tree", "Run Tree tests").dependOn(&tree_test_artifact.step);

        const iterator_tests = b.addTest(.{ .root_source_file = b.path("src/iterator_test.zig") });
        iterator_tests.root_module.addImport("lmdb", lmdb);
        const iterator_test_artifact = b.addRunArtifact(iterator_tests);
        b.step("test-iterator", "Run Iterator tests").dependOn(&iterator_test_artifact.step);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&header_test_artifact.step);
        test_step.dependOn(&builder_test_artifact.step);
        test_step.dependOn(&cursor_test_artifact.step);
        test_step.dependOn(&tree_test_artifact.step);
        test_step.dependOn(&iterator_test_artifact.step);
    }

    {
        // Tree effect simulations
        const effect = b.addExecutable(.{
            .name = "bench-effect",
            .root_source_file = b.path("benchmarks/effects.zig"),
            .optimize = .ReleaseFast,
            .target = target,
        });

        effect.root_module.addImport("lmdb", lmdb);
        effect.root_module.addImport("okra", okra);

        const run_effects = b.addRunArtifact(effect);
        b.step("bench-effect", "Collect Tree effect stats").dependOn(&run_effects.step);
    }

    // Benchmarks
    const benchmark = b.addExecutable(.{
        .name = "okra-benchmark",
        .root_source_file = b.path("benchmarks/main.zig"),
        .optimize = .ReleaseFast,
        .target = target,
    });

    benchmark.root_module.addImport("lmdb", lmdb);
    benchmark.root_module.addImport("okra", okra);

    const benchmark_artifact = b.addRunArtifact(benchmark);
    b.step("bench", "Run Okra benchmarks").dependOn(&benchmark_artifact.step);
}
