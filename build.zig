const std = @import("std");
const FileSource = std.build.FileSource;

const lmdb_source_files = [_][]const u8{
    "libs/openldap/libraries/liblmdb/mdb.c",
    "libs/openldap/libraries/liblmdb/midl.c",
};

pub fn build(b: *std.build.Builder) void {

    // build CLI
    const cli = b.addExecutable(.{
        .name = "okra",
        .root_source_file = FileSource.relative("./cli/main.zig"),
    });

    const zig_cli = b.createModule(.{
        .source_file = FileSource.relative("./libs/zig-cli/src/main.zig"),
    });

    const lmdb = b.addModule("lmdb", .{
        .source_file = FileSource.relative("lmdb/lib.zig"),
    });

    const okra = b.addModule("okra", .{
        .source_file = FileSource.relative("src/lib.zig"),
        .dependencies = &.{.{ .name = "lmdb", .module = lmdb }},
    });

    cli.addModule("zig-cli", zig_cli);
    cli.addModule("lmdb", lmdb);
    cli.addModule("okra", okra);

    cli.addIncludePath(.{ .path = "./libs/openldap/libraries/liblmdb" });
    cli.addCSourceFiles(&lmdb_source_files, &.{});
    cli.linkLibC();
    b.installArtifact(cli);

    // Tests
    const lmdb_tests = b.addTest(.{ .root_source_file = FileSource.relative("lmdb/test.zig") });
    lmdb_tests.addIncludePath(.{ .path = "./libs/openldap/libraries/liblmdb" });
    lmdb_tests.addCSourceFiles(&lmdb_source_files, &.{});
    const run_lmdb_tests = b.addRunArtifact(lmdb_tests);

    const lmdb_test_step = b.step("test-lmdb", "Run LMDB tests");
    lmdb_test_step.dependOn(&run_lmdb_tests.step);

    const builder_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/builder_test.zig") });
    builder_tests.addModule("lmdb", lmdb);
    builder_tests.addIncludePath(.{ .path = "./libs/openldap/libraries/liblmdb" });
    builder_tests.addCSourceFiles(&lmdb_source_files, &.{});
    const run_builder_tests = b.addRunArtifact(builder_tests);

    const builder_test_step = b.step("test-builder", "Run Builder tests");
    builder_test_step.dependOn(&run_builder_tests.step);

    const header_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/header_test.zig") });
    header_tests.addModule("lmdb", lmdb);
    header_tests.addIncludePath(.{ .path = "libs/openldap/libraries/liblmdb" });
    header_tests.addCSourceFiles(&lmdb_source_files, &.{});
    const run_header_tests = b.addRunArtifact(header_tests);

    const header_test_step = b.step("test-header", "Run Header tests");
    header_test_step.dependOn(&run_header_tests.step);

    const tree_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/tree_test.zig") });
    tree_tests.addModule("lmdb", lmdb);
    tree_tests.addIncludePath(.{ .path = "libs/openldap/libraries/liblmdb" });
    tree_tests.addCSourceFiles(&lmdb_source_files, &.{});
    const run_tree_tests = b.addRunArtifact(tree_tests);

    const tree_test_step = b.step("test-tree", "Run Tree tests");
    tree_test_step.dependOn(&run_tree_tests.step);

    const transaction_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/transaction_test.zig") });
    transaction_tests.addModule("lmdb", lmdb);
    transaction_tests.addIncludePath(.{ .path = "libs/openldap/libraries/liblmdb" });
    transaction_tests.addCSourceFiles(&lmdb_source_files, &.{});
    const run_transaction_tests = b.addRunArtifact(transaction_tests);

    const transaction_test_step = b.step("test-transaction", "Run Transaction tests");
    transaction_test_step.dependOn(&run_transaction_tests.step);

    const iterator_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/iterator_test.zig") });
    iterator_tests.addModule("lmdb", lmdb);
    iterator_tests.addIncludePath(.{ .path = "libs/openldap/libraries/liblmdb" });
    iterator_tests.addCSourceFiles(&lmdb_source_files, &.{});
    const run_iterator_tests = b.addRunArtifact(iterator_tests);

    var iterator_test_step = b.step("test-iterator", "Run iterator tests");
    iterator_test_step.dependOn(&run_iterator_tests.step);

    const effects_tests = b.addTest(.{ .root_source_file = FileSource.relative("src/effects_test.zig") });
    effects_tests.addModule("lmdb", lmdb);
    effects_tests.addIncludePath(.{ .path = "libs/openldap/libraries/liblmdb" });
    effects_tests.addCSourceFiles(&lmdb_source_files, &.{});
    const run_effects_tests = b.addRunArtifact(effects_tests);

    const effects_test_step = b.step("test-effects", "Run effects tests");
    effects_test_step.dependOn(&run_effects_tests.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lmdb_tests.step);
    test_step.dependOn(&run_builder_tests.step);
    test_step.dependOn(&run_header_tests.step);
    test_step.dependOn(&run_tree_tests.step);
    test_step.dependOn(&run_transaction_tests.step);
    test_step.dependOn(&run_iterator_tests.step);

    // Benchmarks

    const lmdb_bench = b.addTest(.{ .root_source_file = FileSource.relative("benchmarks/lmdb.zig") });
    lmdb_bench.addModule("lmdb", lmdb);
    lmdb_bench.addIncludePath(.{ .path = "libs/openldap/libraries/liblmdb" });
    lmdb_bench.addCSourceFiles(&lmdb_source_files, &.{});
    const run_lmdb_bench = b.addRunArtifact(lmdb_bench);

    const lmdb_bench_step = b.step("bench-lmdb", "Run LMDB benchmarks");
    lmdb_bench_step.dependOn(&run_lmdb_bench.step);

    const okra_bench = b.addTest(.{ .root_source_file = FileSource.relative("benchmarks/okra.zig") });
    okra_bench.addModule("lmdb", lmdb);
    okra_bench.addModule("okra", okra);
    okra_bench.addIncludePath(.{ .path = "libs/openldap/libraries/liblmdb" });
    okra_bench.addCSourceFiles(&lmdb_source_files, &.{});
    const run_okra_bench = b.addRunArtifact(lmdb_bench);

    const okra_bench_step = b.step("bench-okra", "Run Okra benchmarks");
    okra_bench_step.dependOn(&run_okra_bench.step);
}
