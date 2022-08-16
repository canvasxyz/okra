const std = @import("std");
const assert = std.debug.assert;

const cli = @import("zig-cli");

const Transaction = @import("./lmdb/transaction.zig").Transaction;
const Cursor = @import("./lmdb/cursor.zig").Cursor;
const compareEntries = @import("./lmdb/compare.zig").compareEntries;

const Tree = @import("./tree.zig").Tree;
const Key = @import("./key.zig").Key;

const printEntries = @import("./print.zig").printEntries;
const utils = @import("./utils.zig");

const allocator = std.heap.c_allocator;

var pathOption = cli.Option{
  .long_name = "path",
  .short_alias = 'p',
  .help = "path to the data directory",
  .value = cli.OptionValue{ .string = null },
  .required = true,
};

var aOption = cli.Option{
  .long_name = "a",
  .help = "path to the first database",
  .value = cli.OptionValue{ .string = null },
  .required = true,
};

var bOption = cli.Option{
  .long_name = "b",
  .help = "path to the second database",
  .value = cli.OptionValue{ .string = null },
  .required = true,
};

const X: comptime_int = 6;

var app = &cli.Command{
  .name = "okra",
  .help = "okra is a deterministic pseudo-random merkle tree built on LMDB",
  .subcommands = &.{
    &cli.Command{
      .name = "cat",
      .help = "print the entries of the database to stdout",
      .options = &.{ &pathOption },
      .action = cat,
    },
    &cli.Command{
      .name = "touch",
      .help = "initialize an empty database",
      .options = &.{ &pathOption },
      .action = touch,
    },
    &cli.Command{
      .name = "diff",
      .help = "print the diff between two databases",
      .options = &.{ &aOption, &bOption },
      .action = diff,
    },
  },
};

fn cat(_: []const []const u8) !void {
  const stdout = std.io.getStdOut().writer();
  const path = pathOption.value.string orelse unreachable;

  try printEntries(X, path, stdout, .{});
}

fn touch(_: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;
  var tree = try Tree(X).open(path, .{
    .log = std.io.getStdOut().writer(),
  });

  tree.close();
}

fn diff(_: []const []const u8) !void {
  const stdout = std.io.getStdOut().writer();
  const a = aOption.value.string orelse unreachable;
  const b = bOption.value.string orelse unreachable;
  _ = try compareEntries(a, b, .{ .log = stdout });
}

pub fn main() !void {
  return cli.run(app, allocator);
}
