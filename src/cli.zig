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

const X: comptime_int = 6;
const K: comptime_int = 2 + X;
const V: comptime_int = 32;
const Q: comptime_int = 0x42;

const Env = Environment(K, V);
const Txn = Transaction(K, V);
const C = Cursor(K, V);
const T = Tree(X, Q);

var pathOption = cli.Option{
  .long_name = "path",
  .short_alias = 'p',
  .help = "path to the database",
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
  .help = "level within the tree (use -1 for the root)",
  .value = cli.OptionValue{ .int = -1 },
  .required = false,
};

var depthOption = cli.Option{
  .long_name = "depth",
  .help = "number of levels to print",
  .value = cli.OptionValue{ .int = 1 },
  .required = false,
};

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
      .name = "ls",
      .help = "list the children of an intermediate node",
      .options = &.{ &pathOption, &levelOption, &depthOption },
      .action = ls,
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

  var env = try Env.open(path, .{});
  defer env.close();

  var txn = try Txn.open(env, true);
  defer txn.abort();

  const dbi = try txn.openDbi();

  var cursor = try C.open(txn, dbi);
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

fn ls(args: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;
  var depth = depthOption.value.int orelse unreachable;
  var level = levelOption.value.int orelse unreachable;

  if (depth < -1) fail("depth must be -1 or a non-negative integer", .{});
  if (level < -1 or level == 0) fail("level must be -1 or a positive integer", .{});

  if (args.len > 1) {
    fail("too many arguments", .{});
  } else if (level != -1 and args.len == 0) {
    fail("you must specify a key for non-root levels", .{});
  } else if (level == -1 and args.len == 1) {
    fail("you cannot specify a key for the root level", .{});
  }

  var key = [_]u8{ 0 } ** X;
  if (args.len > 0) {
    const keyArg = args[0];
    if (keyArg.len != 2 * X) {
      fail("invalid key size - expected exactly {d} hex bytes", .{ X });
    }

    _ = try std.fmt.hexToBytes(&key, keyArg);
  }

  const stdout = std.io.getStdOut().writer();

  var env = try Env.open(path, .{});
  defer env.close();

  var txn = try Txn.open(env, true);
  defer txn.abort();

  const dbi = try txn.openDbi();

  var cursor = try C.open(txn, dbi);
  defer cursor.close();

  var rootLevel: u16 = if (try cursor.goToLast()) |root| T.getLevel(root) else {
    fail("database not initialized", .{});
  };

  if (rootLevel == 1) return Error.InvalidDatabase;

  var initialLevel: u16 = if (level == -1) rootLevel else @intCast(u16, level);
  var initialDepth: u16 = if (depth == -1 or depth > initialLevel) initialLevel else @intCast(u16, depth);

  var firstChild = T.createKey(initialLevel, &key);
  const value = try txn.get(dbi, &firstChild);

  var prefix = try allocator.alloc(u8, 2 * initialDepth);
  defer allocator.free(prefix);

  std.mem.set(u8, prefix, '-');
  try stdout.print("{s}- {s} {s}\n", .{ prefix, T.printKey(&firstChild), hex(value.?) });

  T.setLevel(&firstChild, initialLevel - 1);

  if (initialDepth > 0) {
    try listChildren(prefix, &cursor, &firstChild, initialDepth, stdout);
  }
}

const ListChildrenError = C.Error || std.mem.Allocator.Error || std.fs.File.WriteError;

fn listChildren(
  prefix: []u8,
  cursor: *C,
  firstChild: *const T.Key,
  depth: u16,
  log: std.fs.File.Writer,
) ListChildrenError!void {
  const level = T.getLevel(firstChild);
  prefix[prefix.len-2*depth] = '|';
  prefix[prefix.len-2*depth+1] = ' ';

  var child = try cursor.goToKey(firstChild);

  var childValue = cursor.getCurrentValue();

  while (child) |childKey| {
    if (T.getLevel(childKey) != level) break;

    try log.print("{s}- {s} {s}\n", .{ prefix, T.printKey(childKey), hex(childValue.?) });
    if (depth > 1 and level > 0) {
      var nextChild = T.getChild(childKey);
      try listChildren(prefix, cursor, &nextChild, depth - 1, log);
      T.setLevel(&nextChild, level);
      _ = try cursor.goToKey(&nextChild);
    }

    child = try cursor.goToNext();
    childValue = cursor.getCurrentValue();
    if (childValue) |value| if (T.isSplit(value)) break;
  }

  prefix[prefix.len-2*depth] = '-';
  prefix[prefix.len-2*depth+1] = '-';
}

fn init(args: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;
  const verbose = verboseOption.value.bool;

  if (args.len > 0) {
    fail("too many arguments", .{});
  }

  var tree = try T.open(path, .{
    .log = if (verbose) std.io.getStdOut().writer() else null
  });

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

  var env = try Env.open(path, .{});
  defer env.close();
  var txn = try Txn.open(env, false);
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

  var env = try Env.open(path, .{});
  defer env.close();
  var txn = try Txn.open(env, true);
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

  var env = try Env.open(path, .{});
  defer env.close();
  var txn = try Txn.open(env, false);
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