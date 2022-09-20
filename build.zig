const std = @import("std");

pub fn build(b: *std.build.Builder) void {
  // Standard target options allows the person running `zig build` to choose
  // what target to build for. Here we do not override the defaults, which
  // means any target is allowed, and the default is native. Other options
  // for restricting supported target set are available.
  const target = b.standardTargetOptions(.{});

  // Standard release options allow the person running `zig build` to select
  // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
  const mode = b.standardReleaseOptions();

  buildArchOS(b, "aarch64-macos");
  buildArchOS(b, "aarch64-linux-gnu");
  buildArchOS(b, "aarch64-linux-musl");
  buildArchOS(b, "x86_64-macos");
  buildArchOS(b, "x86_64-linux-gnu");
  buildArchOS(b, "x86_64-linux-musl");

  // Tests
  const lmdb_tests = b.addTest("lmdb/test.zig");
  lmdb_tests.setTarget(target);
  lmdb_tests.setBuildMode(mode);
  lmdb_tests.addIncludeDir("libs/openldap/libraries/liblmdb");
  lmdb_tests.addCSourceFiles(lmdbSources, &.{ });

  const okra_tests = b.addTest("src/test.zig");
  okra_tests.setTarget(target);
  okra_tests.setBuildMode(mode);
  okra_tests.addPackage(lmdb);
  okra_tests.addIncludeDir("libs/openldap/libraries/liblmdb");
  okra_tests.addCSourceFiles(lmdbSources, &.{ });
  
  const source_tests = b.addTest("src/source.zig");
  source_tests.setTarget(target);
  source_tests.setBuildMode(mode);
  source_tests.addPackage(lmdb);
  source_tests.addIncludeDir("libs/openldap/libraries/liblmdb");
  source_tests.addCSourceFiles(lmdbSources, &.{ });
  
  const pipe_tests = b.addTest("src/pipe.zig");
  pipe_tests.setTarget(target);
  pipe_tests.setBuildMode(mode);
  pipe_tests.addPackage(lmdb);
  pipe_tests.addIncludeDir("libs/openldap/libraries/liblmdb");
  pipe_tests.addCSourceFiles(lmdbSources, &.{ });

  const test_step = b.step("test", "Run unit tests");
  test_step.dependOn(&lmdb_tests.step);
  test_step.dependOn(&okra_tests.step);
  test_step.dependOn(&source_tests.step);
  test_step.dependOn(&pipe_tests.step);
}

const lmdb = std.build.Pkg{ .name = "lmdb", .path = .{ .path = "lmdb/lib.zig" } };
const okra = std.build.Pkg{ .name = "okra", .path = .{ .path = "src/lib.zig" }, .dependencies = &.{ lmdb } };

const lmdbSources: []const []const u8 = &.{
  "libs/openldap/libraries/liblmdb/mdb.c",
  "libs/openldap/libraries/liblmdb/midl.c",
};

fn buildArchOS(b: *std.build.Builder, comptime archOS: []const u8) void {
  const mode = b.standardReleaseOptions();
  const target = std.zig.CrossTarget.parse(.{ .arch_os_abi = archOS }) catch unreachable;
  const cli = b.addExecutable("okra", "cli/main.zig");
  cli.setBuildMode(mode);
  cli.setTarget(target);
  cli.addPackagePath("zig-cli", "libs/zig-cli/src/main.zig");
  cli.addPackage(lmdb);
  cli.addPackage(okra);
  cli.addIncludeDir("libs/openldap/libraries/liblmdb");
  cli.addCSourceFiles(lmdbSources, &.{ });
  cli.setOutputDir("zig-out/" ++ archOS);
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