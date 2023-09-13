const std = @import("std");
const FileSource = std.build.FileSource;
const LazyPath = std.build.LazyPath;

const lmdb_source_files = [_][]const u8{
    "libs/zig-lmdb/libs/openldap/libraries/liblmdb/mdb.c",
    "libs/zig-lmdb/libs/openldap/libraries/liblmdb/midl.c",
};

const lmdb_include_path = LazyPath{ .path = "libs/zig-lmdb/libs/openldap/libraries/liblmdb" };

pub fn build(b: *std.build.Builder) void {
    const lmdb = b.anonymousDependency("libs/zig-lmdb/", @import("libs/zig-lmdb/build.zig"), .{});
    const okra = b.addModule("okra", .{
        .source_file = FileSource.relative("src/lib.zig"),
        .dependencies = &.{.{ .name = "lmdb", .module = lmdb.module("lmdb") }},
    });

    {
        // CLI

        const cli = b.addExecutable(.{
            .name = "okra",
            .root_source_file = FileSource.relative("./cli/main.zig"),
        });

        const zig_cli = b.anonymousDependency("libs/zig-cli/", @import("libs/zig-cli/build.zig"), .{});

        cli.addIncludePath(lmdb_include_path);
        cli.addCSourceFiles(&lmdb_source_files, &.{});
        cli.addModule("lmdb", lmdb.module("lmdb"));
        cli.addModule("okra", okra);
        cli.addModule("zig-cli", zig_cli.module("zig-cli"));

        cli.linkLibC();
        b.installArtifact(cli);
    }

    {
        // Tests

        const header_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/header_test.zig") });
        header_tests.addIncludePath(lmdb_include_path);
        header_tests.addCSourceFiles(&lmdb_source_files, &.{});
        header_tests.addModule("lmdb", lmdb.module("lmdb"));
        const run_header_tests = b.addRunArtifact(header_tests);

        b.step("test-header", "Run Header tests").dependOn(&run_header_tests.step);

        const builder_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/builder_test.zig") });
        builder_tests.addIncludePath(lmdb_include_path);
        builder_tests.addCSourceFiles(&lmdb_source_files, &.{});
        builder_tests.addModule("lmdb", lmdb.module("lmdb"));
        const run_builder_tests = b.addRunArtifact(builder_tests);

        b.step("test-builder", "Run Builder tests").dependOn(&run_builder_tests.step);

        const cursor_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/cursor_test.zig") });
        cursor_tests.addIncludePath(lmdb_include_path);
        cursor_tests.addCSourceFiles(&lmdb_source_files, &.{});
        cursor_tests.addModule("lmdb", lmdb.module("lmdb"));
        const run_cursor_tests = b.addRunArtifact(cursor_tests);

        b.step("test-cursor", "Run Cursor tests").dependOn(&run_cursor_tests.step);

        const tree_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/tree_test.zig") });
        tree_tests.addIncludePath(lmdb_include_path);
        tree_tests.addCSourceFiles(&lmdb_source_files, &.{});
        tree_tests.addModule("lmdb", lmdb.module("lmdb"));
        const run_tree_tests = b.addRunArtifact(tree_tests);

        b.step("test-tree", "Run Tree tests").dependOn(&run_tree_tests.step);

        const iterator_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/iterator_test.zig") });
        iterator_tests.addIncludePath(lmdb_include_path);
        iterator_tests.addCSourceFiles(&lmdb_source_files, &.{});
        iterator_tests.addModule("lmdb", lmdb.module("lmdb"));
        const run_iterator_tests = b.addRunArtifact(iterator_tests);

        b.step("test-iterator", "Run iterator tests").dependOn(&run_iterator_tests.step);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_header_tests.step);
        test_step.dependOn(&run_builder_tests.step);
        test_step.dependOn(&run_cursor_tests.step);
        test_step.dependOn(&run_tree_tests.step);
        test_step.dependOn(&run_iterator_tests.step);
    }

    {
        // Effect simulations
        const effect = b.addExecutable(.{
            .name = "bench-effect",
            .root_source_file = FileSource.relative("benchmarks/effects.zig"),
            .optimize = .ReleaseFast,
        });

        effect.addIncludePath(lmdb_include_path);
        effect.addCSourceFiles(&lmdb_source_files, &.{});
        effect.addModule("lmdb", lmdb.module("lmdb"));
        effect.addModule("okra", okra);

        const run_effects = b.addRunArtifact(effect);
        b.step("bench-effect", "Run effect benchmarks").dependOn(&run_effects.step);
    }

    // // Benchmarks

    // const lmdb_bench = b.addTest(.{ .root_source_file = FileSource.relative("benchmarks/lmdb.zig") });
    // lmdb_bench.addModule("lmdb", lmdb);
    // lmdb_bench.addIncludePath(.{ .path = "libs/openldap/libraries/liblmdb" });
    // lmdb_bench.addCSourceFiles(&lmdb_source_files, &.{});
    // const run_lmdb_bench = b.addRunArtifact(lmdb_bench);

    // const lmdb_bench_step = b.step("bench-lmdb", "Run LMDB benchmarks");
    // lmdb_bench_step.dependOn(&run_lmdb_bench.step);

    // const okra_bench = b.addTest(.{ .root_source_file = FileSource.relative("benchmarks/okra.zig") });
    // okra_bench.addModule("lmdb", lmdb);
    // okra_bench.addModule("okra", okra);
    // okra_bench.addIncludePath(.{ .path = "libs/openldap/libraries/liblmdb" });
    // okra_bench.addCSourceFiles(&lmdb_source_files, &.{});
    // const run_okra_bench = b.addRunArtifact(lmdb_bench);

    // const okra_bench_step = b.step("bench-okra", "Run Okra benchmarks");
    // okra_bench_step.dependOn(&run_okra_bench.step);
}
