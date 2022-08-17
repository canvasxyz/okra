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

  const exe = b.addExecutable("okra", "src/cli.zig");
  exe.setTarget(target);
  exe.setBuildMode(mode);
  exe.addPackagePath("zig-cli", "libs/zig-cli/src/main.zig");
  exe.addIncludeDir("libs/openldap/libraries/liblmdb");
  exe.addCSourceFile("libs/openldap/libraries/liblmdb/mdb.c", &.{ "-fno-sanitize=undefined" });
  exe.addCSourceFile("libs/openldap/libraries/liblmdb/midl.c", &.{ "-fno-sanitize=undefined" });
  exe.install();

  const run_cmd = exe.run();
  run_cmd.step.dependOn(b.getInstallStep());
  if (b.args) |args| {
    run_cmd.addArgs(args);
  }

  const run_step = b.step("run", "Run the app");
  run_step.dependOn(&run_cmd.step);

  const lmdb_tests = b.addTest("src/lmdb/test.zig");
  lmdb_tests.setTarget(target);
  lmdb_tests.setBuildMode(mode);
  lmdb_tests.addIncludeDir("libs/openldap/libraries/liblmdb");
  lmdb_tests.addCSourceFile("libs/openldap/libraries/liblmdb/mdb.c", &.{ "-fno-sanitize=undefined" });
  lmdb_tests.addCSourceFile("libs/openldap/libraries/liblmdb/midl.c", &.{ "-fno-sanitize=undefined" });

  const tree_tests = b.addTest("src/test.zig");
  tree_tests.setTarget(target);
  tree_tests.setBuildMode(mode);
  tree_tests.addIncludeDir("libs/openldap/libraries/liblmdb");
  tree_tests.addCSourceFile("libs/openldap/libraries/liblmdb/mdb.c", &.{ "-fno-sanitize=undefined" });
  tree_tests.addCSourceFile("libs/openldap/libraries/liblmdb/midl.c", &.{ "-fno-sanitize=undefined" });
  
  const scanner_tests = b.addTest("src/scanner.zig");
  scanner_tests.setTarget(target);
  scanner_tests.setBuildMode(mode);
  scanner_tests.addIncludeDir("libs/openldap/libraries/liblmdb");
  scanner_tests.addCSourceFile("libs/openldap/libraries/liblmdb/mdb.c", &.{ "-fno-sanitize=undefined" });
  scanner_tests.addCSourceFile("libs/openldap/libraries/liblmdb/midl.c", &.{ "-fno-sanitize=undefined" });

  const test_step = b.step("test", "Run unit tests");
  test_step.dependOn(&lmdb_tests.step);
  test_step.dependOn(&tree_tests.step);
  test_step.dependOn(&scanner_tests.step);
}
