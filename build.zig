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

  const lmdb = std.build.Pkg{ .name = "lmdb", .path = .{ .path = "lmdb/lib.zig" } };
  const okra = std.build.Pkg{ .name = "okra", .path = .{ .path = "src/lib.zig" }, .dependencies = &.{ lmdb } };

  const lmdbSources: []const []const u8 = &.{
    "libs/openldap/libraries/liblmdb/mdb.c",
    "libs/openldap/libraries/liblmdb/midl.c",
  };

  const cli = b.addExecutable("okra", "cli/main.zig");
  cli.setTarget(target);
  cli.setBuildMode(mode);
  cli.addPackagePath("zig-cli", "libs/zig-cli/src/main.zig");
  cli.addPackage(lmdb);
  cli.addPackage(okra);
  cli.addIncludeDir("libs/openldap/libraries/liblmdb");
  cli.addCSourceFiles(lmdbSources, &.{ });
  cli.install();

  const run_cmd = cli.run();
  run_cmd.step.dependOn(b.getInstallStep());
  if (b.args) |args| run_cmd.addArgs(args);

  const run_step = b.step("run", "Run the CLI");
  run_step.dependOn(&run_cmd.step);

  const napi = b.addSharedLibrary("okra", "napi/lib.zig", .unversioned);
  napi.setTarget(target);
  napi.setBuildMode(mode);
  napi.addPackage(okra);
  napi.addIncludeDir("/usr/local/include/node");
  napi.addIncludeDir("libs/openldap/libraries/liblmdb");
  napi.addCSourceFiles(lmdbSources, &.{ });
  napi.linker_allow_shlib_undefined = true;
  napi.install();

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
  
  const scanner_tests = b.addTest("src/scanner.zig");
  scanner_tests.setTarget(target);
  scanner_tests.setBuildMode(mode);
  scanner_tests.addPackage(lmdb);
  scanner_tests.addIncludeDir("libs/openldap/libraries/liblmdb");
  scanner_tests.addCSourceFiles(lmdbSources, &.{ });

  const test_step = b.step("test", "Run unit tests");
  test_step.dependOn(&lmdb_tests.step);
  test_step.dependOn(&okra_tests.step);
  test_step.dependOn(&scanner_tests.step);
}
