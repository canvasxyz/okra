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
    // cli.setBuildMode(mode);
    cli.addPackagePath("zig-cli", "./libs/zig-cli/src/main.zig");
    cli.addPackage(lmdb);
    cli.addPackage(okra);
    cli.addIncludePath("./libs/openldap/libraries/liblmdb");
    cli.addCSourceFiles(lmdbSources, &.{ });
    cli.linkLibC();
    cli.install();

    // // build node-api dylib
    // const napi = b.addSharedLibrary("okra", "./napi/lib.zig", .unversioned);
    // // napi.setBuildMode(mode);
    // napi.addPackage(okra);
    // napi.addIncludePath("/usr/local/include/node");
    // napi.addIncludePath("./libs/openldap/libraries/liblmdb");
    // napi.addCSourceFiles(lmdbSources, &.{ });
    // napi.linkLibC();
    // napi.linker_allow_shlib_undefined = true;
    // napi.install();

    // buildArchOS(b, "aarch64-macos");
    // buildArchOS(b, "aarch64-linux-gnu");
    // buildArchOS(b, "aarch64-linux-musl");
    // buildArchOS(b, "x86_64-macos");
    // buildArchOS(b, "x86_64-linux-gnu");
    // buildArchOS(b, "x86_64-linux-musl");

    // Tests
    const lmdb_tests = b.addTest("lmdb/test.zig");
    lmdb_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    lmdb_tests.addCSourceFiles(lmdbSources, &.{ });
    var lmdb_test_step = b.step("test-lmdb", "Run LMDB tests");
    lmdb_test_step.dependOn(&lmdb_tests.step);

    const builder_tests = b.addTest("src/Builder.zig");
    builder_tests.addPackage(lmdb);
    builder_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    builder_tests.addCSourceFiles(lmdbSources, &.{ });

    var builder_test_step = b.step("test-builder", "Run Builder tests");
    builder_test_step.dependOn(&builder_tests.step);

    const skip_list_tests = b.addTest("src/SkipList.zig");
    skip_list_tests.addPackage(lmdb);
    skip_list_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    skip_list_tests.addCSourceFiles(lmdbSources, &.{ });

    var skip_list_test_step = b.step("test-skip-list", "Run SkipList tests");
    skip_list_test_step.dependOn(&skip_list_tests.step);

    const okra_tests = b.addTest("src/test.zig");
    okra_tests.addPackage(lmdb);
    okra_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    okra_tests.addCSourceFiles(lmdbSources, &.{ });

    // const source_tests = b.addTest("src/source.zig");
    // source_tests.addPackage(lmdb);
    // source_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    // source_tests.addCSourceFiles(lmdbSources, &.{ });

    // const driver_tests = b.addTest("src/driver.zig");
    // driver_tests.addPackage(lmdb);
    // driver_tests.addIncludePath("libs/openldap/libraries/liblmdb");
    // driver_tests.addCSourceFiles(lmdbSources, &.{ });

    const test_step = b.step("test", "Run unit tests");

    // test_step.dependOn(lmdb_test_step);
    // test_step.dependOn(builder_test_step);
    // test_step.dependOn(skip_list_test_step);
    test_step.dependOn(&okra_tests.step);
    // test_step.dependOn(&source_tests.step);
    // test_step.dependOn(&driver_tests.step);
}

const lmdb = std.build.Pkg{
    .name = "lmdb",
    .source = .{ .path = "lmdb/lib.zig" },
};

const okra = std.build.Pkg{
    .name = "okra",
    .source = .{ .path = "src/lib.zig" },
    .dependencies = &.{ lmdb },
};

const lmdbSources: []const []const u8 = &.{
    "libs/openldap/libraries/liblmdb/mdb.c",
    "libs/openldap/libraries/liblmdb/midl.c",
};

fn buildArchOS(b: *std.build.Builder, comptime _: []const u8) void {
    const mode = b.standardReleaseOptions();
    // const target = std.zig.CrossTarget.parse(.{ .arch_os_abi = archOS }) catch unreachable;

    const cli = b.addExecutable("okra", "./cli/main.zig");
    cli.setBuildMode(mode);
    // cli.setTarget(target);
    cli.addPackagePath("zig-cli", "./libs/zig-cli/src/main.zig");
    cli.addPackage(lmdb);
    cli.addPackage(okra);
    cli.addIncludePath("./libs/openldap/libraries/liblmdb");
    cli.addCSourceFiles(lmdbSources, &.{ });
    // cli.setOutputDir("zig-out/" ++ archOS);
    cli.linkLibC();
    cli.install();

    // const napi = b.addSharedLibrary("okra", "napi/lib.zig", .unversioned);
    // napi.setBuildMode(mode);
    // napi.setTarget(target);
    // napi.addPackage(okra);
    // napi.addIncludeDir("/usr/local/include/node");
    // napi.addIncludeDir("libs/openldap/libraries/liblmdb");
    // napi.addCSourceFiles(lmdbSources, &.{ });
    // napi.setOutputDir("zig-out/" ++ archOS);
    // napi.linkLibC();
    // napi.linker_allow_shlib_undefined = true;
    // napi.install();
}