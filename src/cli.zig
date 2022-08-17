const std = @import("std");
const assert = std.debug.assert;
const hex = std.fmt.fmtSliceHexLower;

const cli = @import("zig-cli");

const Environment = @import("./lmdb/environment.zig").Environment;
const Transaction = @import("./lmdb/transaction.zig").Transaction;
const Cursor = @import("./lmdb/cursor.zig").Cursor;
const compareEntries = @import("./lmdb/compare.zig").compareEntries;

const Tree = @import("./tree.zig").Tree;

const allocator = std.heap.c_allocator;

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

var pathOption = cli.Option{
  .long_name = "path",
  .short_alias = 'p',
  .help = "path to the database",
  .value = cli.OptionValue{ .string = null },
  .required = true,
};

var verboseOption = cli.Option{
  .long_name = "verbose",
  .short_alias = 'v',
  .help = "print debugging log to stdout",
  .value = cli.OptionValue{ .bool = false },
};

var internalOption = cli.Option{
  .long_name = "internal",
  .help = "access the underlying LMDB database",
  .value = cli.OptionValue{ .bool = false },
  .required = false,
};

var levelOption = cli.Option{
  .long_name = "level",
  .help = "level within the tree (the leaf level is level 0)",
  .value = cli.OptionValue{ .int = 0 },
  .required = false,
};

const X: comptime_int = 6;
const K: comptime_int = 2 + X;
const V: comptime_int = 32;
const Q: comptime_int = 0x30;

var app = &cli.Command{
  .name = "okra",
  .help = "okra is a deterministic pseudo-random merkle tree built on LMDB",
  .subcommands = &.{
    &cli.Command{
      .name = "cat",
      .help = "print the entries of the database to stdout",
      .options = &.{ &internalOption, &pathOption },
      .action = cat,
    },
    &cli.Command{
      .name = "init",
      .help = "initialize an empty database",
      .options = &.{ &pathOption, &verboseOption },
      .action = init,
    },
    &cli.Command{
      .name = "diff",
      .help = "print the diff between two databases",
      .options = &.{ &internalOption, &aOption, &bOption },
      .action = diff,
    },
    &cli.Command{
      .name = "get",
      .help = "get the value for a key",
      .options = &.{ &internalOption, &pathOption },
      .action = get,
    },
    &cli.Command{
      .name = "set",
      .help = "set a key/value entry",
      .options = &.{ &internalOption, &pathOption, &verboseOption },
      .action = set,
    },
    &cli.Command{
      .name = "delete",
      .help = "delete a key",
      .options = &.{ &internalOption, &pathOption },
      .action = delete,
    },
  },
};

fn cat(args: []const []const u8) !void {
  const internal = internalOption.value.bool;
  const path = pathOption.value.string orelse unreachable;

  if (args.len > 0) {
    fail("too many arguments", .{});
  }

  const stdout = std.io.getStdOut().writer();

  var env = try Environment(K, V).open(path, .{});
  defer env.close();

  var txn = try Transaction(K, V).open(env, true);
  defer txn.abort();

  const dbi = try txn.openDbi();

  var cursor = try Cursor(K, V).open(txn, dbi);
  defer cursor.close();

  if (internal) {
    var next = try cursor.goToFirst();
    while (next) |key| : (next = try cursor.goToNext()) {
      const value = cursor.getCurrentValue() orelse @panic("internal error: no value for key");
      try stdout.print("{s} {s}\n", .{ hex(key), hex(value) });
    }
  } else {
    const anchorKey = [_]u8{ 0 } ** K;
    if (try cursor.goToFirst()) |firstKey| {
      if (!std.mem.eql(u8, firstKey, &anchorKey)) return Error.InvalidDatabase;
      const firstValue = cursor.getCurrentValue() orelse return Error.InvalidDatabase;
      if (!isZero(firstValue)) return Error.InvalidDatabase;
      while (try cursor.goToNext()) |key| {
        if (std.mem.readIntBig(u16, key[0..2]) > 0) break;
        const value = cursor.getCurrentValue() orelse @panic("internal error: no value for key");
        try stdout.print("{s} {s}\n", .{ hex(key[2..]), hex(value) });
      }
    }
  }
}

fn init(args: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;

  if (args.len > 0) {
    fail("too many arguments", .{});
  }

  var tree = try Tree(X, Q).open(path, .{});
  tree.close();
}

fn diff(args: []const []const u8) !void {
  const internal = internalOption.value.bool;
  const a = aOption.value.string orelse unreachable;
  const b = bOption.value.string orelse unreachable;

  if (args.len > 0) {
    fail("too many arguments", .{});
  }

  if (!internal) {
    fail("the diff command can only be used with the --internal flag", .{});
  }

  const stdout = std.io.getStdOut().writer();

  _ = try compareEntries(K, V, a, b, .{ .log = stdout });
}

fn set(args: []const []const u8) !void {
  const internal = internalOption.value.bool;
  const path = pathOption.value.string orelse unreachable;

  if (args.len == 0) {
    fail("missing key argument", .{});
  } else if (args.len == 1) {
    fail("missing value argument", .{});
  } else if (args.len > 2) {
    fail("too many arguments", .{});
  }

  const keyArg = args[0];
  const valueArg = args[1];

  const keySize: usize = if (internal) K else X;
  if (keyArg.len != 2 * keySize) {
    fail("invalid key size - expected exactly {d} hex bytes", .{ keySize });
  } else if (valueArg.len != 2 * V) {
    fail("invalid value size - expected exactly {d} hex bytes", .{ V });
  }

  var env = try Environment(K, V).open(path, .{});
  defer env.close();
  var txn = try Transaction(K, V).open(env, false);
  errdefer txn.abort();
  const dbi = try txn.openDbi();

  var value = [_]u8{ 0 } ** V;
  _ = try std.fmt.hexToBytes(&value, valueArg);

  var key = [_]u8{ 0 } ** K;
  if (internal) {
    _ = try std.fmt.hexToBytes(&key, keyArg);
  } else {
    _ = try std.fmt.hexToBytes(key[2..], keyArg);
  }

  try txn.set(dbi, &key, &value);
  try txn.commit();
}

fn get(args: []const []const u8) !void {
  const internal = internalOption.value.bool;
  const path = pathOption.value.string orelse unreachable;

  if (args.len == 0) {
    fail("key argument required", .{});
  } else if (args.len > 1) {
    fail("too many arguments", .{});
  }

  const keyArg = args[0];
  const keySize: usize = if (internal) K else X;
  if (keyArg.len != 2 * keySize) {
    fail("invalid key size - expected exactly {d} hex bytes", .{ keySize });
  }

  const stdout = std.io.getStdOut().writer();

  var env = try Environment(K, V).open(path, .{});
  defer env.close();
  var txn = try Transaction(K, V).open(env, true);
  defer txn.abort();
  const dbi = try txn.openDbi();

  var key = [_]u8{ 0 } ** K;
  if (internal) {
    _ = try std.fmt.hexToBytes(&key, keyArg);
  } else {
    _ = try std.fmt.hexToBytes(key[2..], keyArg);
  }

  if (try txn.get(dbi, &key)) |value| {
    try stdout.print("{s}\n", .{ hex(value) });
  }
}

fn delete(args: []const []const u8) !void {
  const internal = internalOption.value.bool;
  const path = pathOption.value.string orelse unreachable;
  if (!internal) {
    fail("the delete command can only be used with the --internal flag", .{});
  }

  if (args.len == 0) {
    fail("key argument required", .{});
  } else if (args.len > 1) {
    fail("too many arguments", .{});
  }

  const keyArg = args[0];
  const keySize = K;
  if (keyArg.len != 2 * keySize) {
    fail("invalid key size - expected exactly {d} hex bytes", .{ keySize });
  }

  var env = try Environment(K, V).open(path, .{});
  defer env.close();
  var txn = try Transaction(K, V).open(env, false);
  errdefer txn.abort();
  const dbi = try txn.openDbi();
  
  var key = [_]u8{ 0 } ** K;
  _ = try std.fmt.hexToBytes(&key, keyArg);
  try txn.delete(dbi, &key);
  try txn.commit();
}

const Error = error {
  InvalidDatabase,
};

pub fn main() !void {
  return cli.run(app, allocator);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
  var w = std.io.getStdErr().writer();
  std.fmt.format(w, "ERROR: ", .{}) catch unreachable;
  std.fmt.format(w, fmt, args) catch unreachable;
  std.fmt.format(w, "\n", .{}) catch unreachable;
  std.os.exit(1);
}

fn isZero(data: []const u8) bool {
  for (data) |byte| if (byte != 0) return false;
  return true;
}