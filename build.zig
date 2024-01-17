const std = @import("std");
const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = optimize; // autofix

    const lmdb = b.dependency("lmdb", .{});

    const okra = b.addModule("okra", .{
        .root_source_file = LazyPath.relative("src/lib.zig"),
    });

    okra.addImport("lmdb", lmdb.module("lmdb"));

    // {
    //     // CLI
    //     const cli = b.addExecutable(.{
    //         .name = "okra",
    //         .root_source_file = LazyPath.relative("./cli/main.zig"),
    //         .optimize = optimize,
    //         .target = target,
    //     });

    //     const zig_cli = b.anonymousDependency("libs/zig-cli/", @import("libs/zig-cli/build.zig"), .{});

    //     // cli.addIncludePath(lmdb_include_path);
    //     // cli.addCSourceFiles(&lmdb_source_files, &.{});
    //     cli.root_module.addImport("lmdb", lmdb.module("lmdb"));
    //     cli.root_module.addImport("okra", okra);
    //     cli.root_module.addImport("zig-cli", zig_cli.module("zig-cli"));

    //     cli.linkLibC();
    //     b.installArtifact(cli);

    //     const cli_artifact = b.addInstallArtifact(cli, .{});
    //     b.step("cli", "Build the CLI").dependOn(&cli_artifact.step);
    // }

    // const tests = b.addTest(.{ .root_source_file = LazyPath.relative("test/main.zig") });
    // tests.root_module.addImport("lmdb", lmdb.module("lmdb"));
    // // tests.root_module.addImport("okra", okra);

    // const test_runner = b.addRunArtifact(tests);
    // b.step("test", "Run unit tests").dependOn(&test_runner.step);

    {
        // Tests
        const header_tests = b.addTest(.{ .root_source_file = LazyPath.relative("src/header_test.zig") });
        header_tests.root_module.addImport("lmdb", lmdb.module("lmdb"));
        const header_test_artifact = b.addRunArtifact(header_tests);
        b.step("test-header", "Run Header tests").dependOn(&header_test_artifact.step);

        const builder_tests = b.addTest(.{ .root_source_file = LazyPath.relative("src/builder_test.zig") });
        builder_tests.root_module.addImport("lmdb", lmdb.module("lmdb"));
        const builder_test_artifact = b.addRunArtifact(builder_tests);
        b.step("test-builder", "Run Builder tests").dependOn(&builder_test_artifact.step);

        const cursor_tests = b.addTest(.{ .root_source_file = LazyPath.relative("src/cursor_test.zig") });
        cursor_tests.root_module.addImport("lmdb", lmdb.module("lmdb"));
        const cursor_test_artifact = b.addRunArtifact(cursor_tests);
        b.step("test-cursor", "Run Cursor tests").dependOn(&cursor_test_artifact.step);

        const tree_tests = b.addTest(.{ .root_source_file = LazyPath.relative("src/tree_test.zig") });
        tree_tests.root_module.addImport("lmdb", lmdb.module("lmdb"));
        const tree_test_artifact = b.addRunArtifact(tree_tests);
        b.step("test-tree", "Run Tree tests").dependOn(&tree_test_artifact.step);

        const iterator_tests = b.addTest(.{ .root_source_file = LazyPath.relative("src/iterator_test.zig") });
        iterator_tests.root_module.addImport("lmdb", lmdb.module("lmdb"));
        const iterator_test_artifact = b.addRunArtifact(iterator_tests);
        b.step("test-iterator", "Run Iterator tests").dependOn(&iterator_test_artifact.step);

        const skiplist_tests = b.addTest(.{ .root_source_file = LazyPath.relative("src/skiplist_test.zig") });
        skiplist_tests.root_module.addImport("lmdb", lmdb.module("lmdb"));
        const skiplist_test_artifact = b.addRunArtifact(skiplist_tests);
        b.step("test-skiplist", "Run SkipList tests").dependOn(&skiplist_test_artifact.step);

        // const test_step = b.step("test", "Run unit tests");
        // test_step.dependOn(&run_header_tests.step);
        // test_step.dependOn(&run_builder_tests.step);
        // test_step.dependOn(&run_cursor_tests.step);
        // test_step.dependOn(&run_tree_tests.step);
        // test_step.dependOn(&run_iterator_tests.step);
    }

    {
        // Tree effect simulations
        const effect = b.addExecutable(.{
            .name = "bench-effect",
            .root_source_file = LazyPath.relative("benchmarks/effects.zig"),
            .optimize = .ReleaseFast,
            .target = target,
        });

        effect.root_module.addImport("lmdb", lmdb.module("lmdb"));
        effect.root_module.addImport("okra", okra);

        const run_effects = b.addRunArtifact(effect);
        b.step("bench-effect", "Collect tree effect stats").dependOn(&run_effects.step);
    }

    {
        // Skiplist effect simulations
        const effect = b.addExecutable(.{
            .name = "bench-effect-skiplist",
            .root_source_file = LazyPath.relative("benchmarks/effects_sl.zig"),
            .optimize = .ReleaseFast,
            .target = target,
        });

        effect.root_module.addImport("lmdb", lmdb.module("lmdb"));
        effect.root_module.addImport("okra", okra);

        const run_effects = b.addRunArtifact(effect);
        b.step("bench-effect-skiplist", "Collect skiplist effect stats").dependOn(&run_effects.step);
    }

    // Benchmarks
    const benchmark = b.addExecutable(.{
        .name = "okra-benchmark",
        .root_source_file = LazyPath.relative("benchmarks/main.zig"),
        .optimize = .ReleaseFast,
        .target = target,
    });

    benchmark.root_module.addImport("lmdb", lmdb.module("lmdb"));
    benchmark.root_module.addImport("okra", okra);

    const benchmark_artifact = b.addRunArtifact(benchmark);
    b.step("bench", "Run Okra benchmarks").dependOn(&benchmark_artifact.step);
}
