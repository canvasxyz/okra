const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    // const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    // const mode = b.standardReleaseOptions();

    // build CLI
    const cli = b.addExecutable("okra", "./cli/main.zig");
    cli.addPackagePath("zig-cli", "./libs/zig-cli/src/main.zig");
    cli.addPackage(lmdb);
    cli.addPackage(okra);
    cli.addIncludePath("./libs/openldap/libraries/liblmdb");
    cli.addCSourceFiles(lmdbSources, &.{});
    cli.linkLibC();
    cli.install();

    // build node-api dylib
    const napi = b.addSharedLibrary("okra", "./napi/lib.zig", .unversioned);
    napi.addPackage(okra);
    napi.addIncludePath("/usr/local/include/node");
    napi.addIncludePath("./libs/openldap/libraries/liblmdb");
    napi.addCSourceFiles(lmdbSources, &.{});
    napi.linkLibC();
    napi.linker_allow_shlib_undefined = true;
    napi.install();

    // buildArchOS(b, "aarch64-macos");
    // buildArchOS(b, "aarch64-linux-gnu");
    // buildArchOS(b, "aarch64-linux-musl");
    // buildArchOS(b, "x86_64-macos");
    // buildArchOS(b, "x86_64-linux-gnu");
    // buildArchOS(b, "x86_64-linux-musl");

    // Tests
    const lmdb_tests = b.addTest("lmdb/test.zig");
    lmdb_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    lmdb_tests.addCSourceFiles(lmdbSources, &.{});
    var lmdb_test_step = b.step("test-lmdb", "Run LMDB tests");
    lmdb_test_step.dependOn(&lmdb_tests.step);

    const builder_tests = b.addTest("src/builder_test.zig");
    builder_tests.addPackage(lmdb);
    builder_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    builder_tests.addCSourceFiles(lmdbSources, &.{});
    var builder_test_step = b.step("test-builder", "Run Builder tests");
    builder_test_step.dependOn(&builder_tests.step);

    const header_tests = b.addTest("src/header_test.zig");
    header_tests.addPackage(lmdb);
    header_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    header_tests.addCSourceFiles(lmdbSources, &.{});
    var header_test_step = b.step("test-header", "Run Header tests");
    header_test_step.dependOn(&header_tests.step);

    const tree_tests = b.addTest("src/tree_test.zig");
    tree_tests.addPackage(lmdb);
    tree_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    tree_tests.addCSourceFiles(lmdbSources, &.{});
    var tree_test_step = b.step("test-tree", "Run Tree tests");
    tree_test_step.dependOn(&tree_tests.step);

    const transaction_tests = b.addTest("src/transaction_test.zig");
    transaction_tests.addPackage(lmdb);
    transaction_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    transaction_tests.addCSourceFiles(lmdbSources, &.{});
    var transaction_test_step = b.step("test-transaction", "Run Transaction tests");
    transaction_test_step.dependOn(&transaction_tests.step);

    const cursor_tests = b.addTest("src/cursor_test.zig");
    cursor_tests.addPackage(lmdb);
    cursor_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    cursor_tests.addCSourceFiles(lmdbSources, &.{});
    var cursor_test_step = b.step("test-cursor", "Run cursor tests");
    cursor_test_step.dependOn(&cursor_tests.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(lmdb_test_step);
    test_step.dependOn(builder_test_step);
    test_step.dependOn(header_test_step);
    test_step.dependOn(tree_test_step);
    test_step.dependOn(transaction_test_step);
    test_step.dependOn(cursor_test_step);

    const lmdb_bench = b.addTest("lmdb/benchmark.zig");
    lmdb_bench.setBuildMode(std.builtin.Mode.ReleaseFast);
    lmdb_bench.addIncludePath("libs/openldap/libraries/liblmdb");
    lmdb_bench.addCSourceFiles(lmdbSources, &.{});
    var lmdb_bench_step = b.step("bench-lmdb", "Run LMDB benchmarks");
    lmdb_bench_step.dependOn(&lmdb_bench.step);

    const bench = b.addTest("src/benchmark.zig");
    bench.setBuildMode(std.builtin.Mode.ReleaseFast);
    bench.addPackage(lmdb);
    bench.addIncludePath("libs/openldap/libraries/liblmdb");
    bench.addCSourceFiles(lmdbSources, &.{});
    var bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench.step);
}

const lmdb = std.build.Pkg{
    .name = "lmdb",
    .source = .{ .path = "lmdb/lib.zig" },
};

const okra = std.build.Pkg{
    .name = "okra",
    .source = .{ .path = "src/lib.zig" },
    .dependencies = &.{lmdb},
};

const lmdbSources: []const []const u8 = &.{
    "libs/openldap/libraries/liblmdb/mdb.c",
    "libs/openldap/libraries/liblmdb/midl.c",
};

// fn buildArchOS(b: *std.build.Builder, comptime _: []const u8) void {
//     const mode = b.standardReleaseOptions();
//     // const target = std.zig.CrossTarget.parse(.{ .arch_os_abi = archOS }) catch unreachable;

//     const cli = b.addExecutable("okra", "./cli/main.zig");
//     cli.setBuildMode(mode);
//     // cli.setTarget(target);
//     cli.addPackagePath("zig-cli", "./libs/zig-cli/src/main.zig");
//     cli.addPackage(lmdb);
//     cli.addPackage(okra);
//     cli.addIncludePath("./libs/openldap/libraries/liblmdb");
//     cli.addCSourceFiles(lmdbSources, &.{});
//     // cli.setOutputDir("zig-out/" ++ archOS);
//     cli.linkLibC();
//     cli.install();

//     // const napi = b.addSharedLibrary("okra", "napi/lib.zig", .unversioned);
//     // napi.setBuildMode(mode);
//     // napi.setTarget(target);
//     // napi.addPackage(okra);
//     // napi.addIncludeDir("/usr/local/include/node");
//     // napi.addIncludeDir("libs/openldap/libraries/liblmdb");
//     // napi.addCSourceFiles(lmdbSources, &.{ });
//     // napi.setOutputDir("zig-out/" ++ archOS);
//     // napi.linkLibC();
//     // napi.linker_allow_shlib_undefined = true;
//     // napi.install();
// }
