const std = @import("std");
const assert = std.debug.assert;
const hex = std.fmt.fmtSliceHexLower;
const Sha256 = std.crypto.hash.sha2.Sha256;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const X: comptime_int = 6;
const K: comptime_int = 2 + X;
const V: comptime_int = 32;
const Q: comptime_int = 0x42;

const Env = lmdb.Environment(K, V);
const Txn = lmdb.Transaction(K, V);
const C = lmdb.Cursor(K, V);
const T = okra.Tree(X, Q);
const B = okra.Builder(X, Q);

const allocator = std.heap.c_allocator;

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

var iotaOption = cli.Option{
  .long_name = "iota",
  .help = "initialize the tree with hashes of the first iota positive integers as sample data",
  .value = cli.OptionValue{ .int = 0 },
};

var levelOption = cli.Option{
  .long_name = "level",
  .short_alias = 'l',
  .help = "level within the tree (use -1 for the root)",
  .value = cli.OptionValue{ .int = -1 },
  .required = false,
};

var depthOption = cli.Option{
  .long_name = "depth",
  .short_alias = 'd',
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
      .options = &.{ &pathOption },
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
      .options = &.{ &pathOption, &verboseOption, &iotaOption },
      .action = init,
    },
    &cli.Command{
      .name = "insert",
      .help = "insert a new leaf",
      .options = &.{ &pathOption, &verboseOption },
      .action = insert,
    },
    &cli.Command{
      .name = "rebuild",
      .help = "rebuild the tree from the leaf layer",
      .options = &.{ &pathOption },
      .action = rebuild,
    },
    &cli.Command{
      .name = "internal",
      .help = "unsafely access the underlying LMDB database directly",
      .subcommands = &.{
        &cli.Command{
          .name = "cat",
          .help = "print the entries of the database to stdout",
          .options = &.{ &pathOption },
          .action = internalCat,
        },
        &cli.Command{
          .name = "get",
          .help = "get the value for a key",
          .description = "okra internal get [KEY]\n[KEY] - hex-encoded key",
          .options = &.{ &pathOption },
          .action = internalGet,
        },
        &cli.Command{
          .name = "set",
          .help = "set a key/value entry",
          .description = "okra internal set [KEY] [VALUE]\n[KEY] - hex-encoded key\n[VALUE] - hex-encoded value",
          .options = &.{ &pathOption },
          .action = internalSet,
        },
        &cli.Command{
          .name = "delete",
          .help = "delete a key",
          .description = "okra internal delete [KEY]\n[KEY] - hex-encoded key",
          .options = &.{ &pathOption },
          .action = internalDelete,
        },
        &cli.Command{
          .name = "diff",
          .help = "print the diff between two databases",
          .description = "okra internal diff [A] [B]\n[A] - path to database file\n[B] - path to database file",
          .options = &.{ &aOption, &bOption },
          .action = internalDiff,
        },
      }
    }
  },
};

fn cat(args: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;

  if (args.len > 0) {
    fail("too many arguments", .{});
  }

  const stdout = std.io.getStdOut().writer();

  var env = try Env.open(getCString(path), .{});
  defer env.close();

  var txn = try Txn.open(env, true);
  defer txn.abort();

  const dbi = try txn.openDBI();

  var cursor = try C.open(txn, dbi);
  defer cursor.close();

  const anchorKey = [_]u8{ 0 } ** K;
  if (try cursor.goToFirst()) |firstKey| {
    if (!std.mem.eql(u8, firstKey, &anchorKey)) return Error.InvalidDatabase;
    const firstValue = try cursor.getCurrentValue();
    if (!isZero(firstValue)) return Error.InvalidDatabase;
    while (try cursor.goToNext()) |key| {
      if (std.mem.readIntBig(u16, key[0..2]) > 0) break;
      const value = try cursor.getCurrentValue();
      try stdout.print("{s} {s}\n", .{ hex(key[2..]), hex(value) });
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
    fail("you must specify a leaf for non-root levels", .{});
  } else if (level == -1 and args.len == 1) {
    fail("you cannot specify a leaf for the root level", .{});
  }

  var leaf = [_]u8{ 0 } ** X;
  if (args.len > 0) {
    const leafArg = args[0];
    if (leafArg.len != 2 * X) {
      fail("invalid leaf size - expected exactly {d} hex bytes", .{ X });
    }

    _ = try std.fmt.hexToBytes(&leaf, leafArg);
  }

  const stdout = std.io.getStdOut().writer();

  var env = try Env.open(getCString(path), .{});
  defer env.close();

  var txn = try Txn.open(env, true);
  defer txn.abort();

  const dbi = try txn.openDBI();

  var cursor = try C.open(txn, dbi);
  defer cursor.close();

  var rootLevel: u16 = if (try cursor.goToLast()) |root| T.getLevel(root) else {
    return fail("database not initialized", .{});
  };

  if (rootLevel == 0) return Error.InvalidDatabase;

  var initialLevel: u16 = if (level == -1) rootLevel else @intCast(u16, level);
  var initialDepth: u16 = if (depth == -1 or depth > initialLevel) initialLevel else @intCast(u16, depth);

  const key = T.createKey(initialLevel, &leaf);
  const value = try txn.get(dbi, &key);
  
  const prefix = try allocator.alloc(u8, 2 * initialDepth);
  defer allocator.free(prefix);
  std.mem.set(u8, prefix, '-');

  prefix[0] = '+';
  try stdout.print("{s}- {s} {s}\n", .{ prefix, T.printKey(&key), hex(value.?) });

  prefix[0] = '|';
  prefix[1] = ' ';
  var firstChild = T.getChild(&key);
  try listChildren(prefix, &cursor, &firstChild, initialDepth, stdout);
}

const ListChildrenError = C.Error || std.mem.Allocator.Error || std.fs.File.WriteError;

fn listChildren(
  prefix: []u8,
  cursor: *C,
  firstChild: *T.Key,
  depth: u16,
  log: std.fs.File.Writer,
) ListChildrenError!void {
  const level = T.getLevel(firstChild);

  prefix[prefix.len-2*depth] = '|';
  prefix[prefix.len-2*depth+1] = ' ';

  try cursor.goToKey(firstChild);
  const firstChildValue = try cursor.getCurrentValue();
  
  if (depth == 1) {
    try log.print("{s}- {s} {s}\n", .{ prefix, T.printKey(firstChild), hex(firstChildValue) });
    while (try cursor.goToNext()) |key| {
      const value = try cursor.getCurrentValue();
      if (T.getLevel(key) != level) break;
      if (T.isSplit(value)) break;
      try log.print("{s}- {s} {s}\n", .{ prefix, T.printKey(key), hex(value) });
    }
  } else if (depth > 1) {
    prefix[prefix.len-2*depth+2] = '+';
    try log.print("{s}- {s} {s}\n", .{ prefix, T.printKey(firstChild), hex(firstChildValue) });

    var grandChild = T.getChild(firstChild);
    try listChildren(prefix, cursor, &grandChild, depth - 1, log);
    try cursor.goToKey(firstChild);
    while (try cursor.goToNext()) |key| {
      const value = try cursor.getCurrentValue();
      if (T.getLevel(key) != level) break;
      if (T.isSplit(value)) break;

      prefix[prefix.len-2*depth+2] = '+';
      try log.print("{s}- {s} {s}\n", .{ prefix, T.printKey(key), hex(value) });
      std.mem.copy(u8, firstChild, key);
      grandChild = T.getChild(key);
      try listChildren(prefix, cursor, &grandChild, depth - 1, log);
      try cursor.goToKey(firstChild);
    }
  } else @panic("depth must be >= 1");

  prefix[prefix.len-2*depth] = '-';
  prefix[prefix.len-2*depth+1] = '-';
}

fn init(args: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;
  const verbose = verboseOption.value.bool;
  const iota = iotaOption.value.int orelse unreachable;
  if (iota < 0) fail("iota must be a non-negative integer", .{});

  if (args.len > 0) {
    fail("too many arguments", .{});
  }

  const log = if (verbose) std.io.getStdOut().writer() else null;
  var tree: T = undefined;
  try tree.init(allocator, getCString(path), .{ .log = log });
  defer tree.close();

  var leaf = [_]u8{ 0 } ** X;
  var value = [_]u8{ 0 } ** V;

  var i: u32 = 0;
  while (i < iota) : (i += 1) {
    std.mem.writeIntBig(u32, leaf[X-4..], i + 1);
    Sha256.hash(&leaf, &value, .{});
    try tree.insert(&leaf, &value);
  }
}

fn insert(args: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;
  const verbose = verboseOption.value.bool;

  if (args.len == 0) {
    fail("missing leaf argument", .{});
  } else if (args.len == 1) {
    fail("missing hash argument", .{});
  } else if (args.len > 2) {
    fail("too many arguments", .{});
  }

  const leafArg = args[0];
  const hashArg = args[1];

  if (leafArg.len != 2 * X) {
    fail("invalid leaf size - expected exactly {d} hex bytes", .{ X });
  } else if (hashArg.len != 2 * V) {
    fail("invalid hash size - expected exactly {d} hex bytes", .{ V });
  }

  var leaf = [_]u8{ 0 } ** X;
  var hash = [_]u8{ 0 } ** V;

  _ = try std.fmt.hexToBytes(&leaf, leafArg);
  _ = try std.fmt.hexToBytes(&hash, hashArg);

  const log = if (verbose) std.io.getStdOut().writer() else null;
  var tree: T = undefined;
  try tree.init(allocator, getCString(path), .{ .log = log });
  defer tree.close();

  try tree.insert(&leaf, &hash);
}

fn rebuild(args: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;
  if (args.len > 0) {
    fail("too many arguments", .{});
  }

  try razeTree(path);

  var builder = try B.init(getCString(path), .{});
  _ = try builder.finalize(null);
  const stdout = std.io.getStdOut().writer();
  try stdout.print("Successfully rebuilt {s}\n", .{ path });
}

fn razeTree(path: []const u8) !void {
  var env = try Env.open(getCString(path), .{});
  defer env.close();

  var txn = try Txn.open(env, false);
  errdefer txn.abort();

  const dbi = try txn.openDBI();

  var cursor = try C.open(txn, dbi);

  const firstKey = T.createKey(1, null);
  try cursor.goToKey(&firstKey);
  try cursor.deleteCurrentKey();
  while (try cursor.goToNext()) |_| try cursor.deleteCurrentKey();

  cursor.close();
  try txn.commit();
}

fn internalCat(args: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;

  if (args.len > 0) {
    fail("too many arguments", .{});
  }

  const stdout = std.io.getStdOut().writer();

  var env = try Env.open(getCString(path), .{});
  defer env.close();

  var txn = try Txn.open(env, true);
  defer txn.abort();

  const dbi = try txn.openDBI();

  var cursor = try C.open(txn, dbi);
  defer cursor.close();

  var next = try cursor.goToFirst();
  while (next) |key| : (next = try cursor.goToNext()) {
    const value = try cursor.getCurrentValue();
    try stdout.print("{s} {s}\n", .{ hex(key), hex(value) });
  }
}

fn internalSet(args: []const []const u8) !void {
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

  if (keyArg.len != 2 * K) {
    fail("invalid key size - expected exactly {d} hex bytes", .{ K });
  } else if (valueArg.len != 2 * V) {
    fail("invalid value size - expected exactly {d} hex bytes", .{ V });
  }

  var env = try Env.open(getCString(path), .{});
  defer env.close();
  var txn = try Txn.open(env, false);
  errdefer txn.abort();
  const dbi = try txn.openDBI();

  var value = [_]u8{ 0 } ** V;
  _ = try std.fmt.hexToBytes(&value, valueArg);

  var key = [_]u8{ 0 } ** K;
  _ = try std.fmt.hexToBytes(&key, keyArg);

  try txn.set(dbi, &key, &value);
  try txn.commit();
}

fn internalGet(args: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;

  if (args.len == 0) {
    fail("key argument required", .{});
  } else if (args.len > 1) {
    fail("too many arguments", .{});
  }

  const keyArg = args[0];
  if (keyArg.len != 2 * K) {
    fail("invalid key size - expected exactly {d} hex bytes", .{ K });
  }

  const stdout = std.io.getStdOut().writer();

  var env = try Env.open(getCString(path), .{});
  defer env.close();
  var txn = try Txn.open(env, true);
  defer txn.abort();
  const dbi = try txn.openDBI();

  var key = [_]u8{ 0 } ** K;
  _ = try std.fmt.hexToBytes(&key, keyArg);

  if (try txn.get(dbi, &key)) |value| {
    try stdout.print("{s}\n", .{ hex(value) });
  }
}

fn internalDelete(args: []const []const u8) !void {
  const path = pathOption.value.string orelse unreachable;

  if (args.len == 0) {
    fail("key argument required", .{});
  } else if (args.len > 1) {
    fail("too many arguments", .{});
  }

  const keyArg = args[0];
  if (keyArg.len != 2 * K) {
    fail("invalid key size - expected exactly {d} hex bytes", .{ K });
  }

  var env = try Env.open(getCString(path), .{});
  defer env.close();
  var txn = try Txn.open(env, false);
  errdefer txn.abort();
  const dbi = try txn.openDBI();
  
  var key = [_]u8{ 0 } ** K;
  _ = try std.fmt.hexToBytes(&key, keyArg);
  try txn.delete(dbi, &key);
  try txn.commit();
}

fn internalDiff(args: []const []const u8) !void {
  const a = aOption.value.string orelse unreachable;
  const b = bOption.value.string orelse unreachable;

  if (args.len > 0) {
    fail("too many arguments", .{});
  }

  const stdout = std.io.getStdOut().writer();

  const pathA = getCString(a);
  const envA = try Env.open(pathA, .{});
  defer envA.close();
  const pathB = getCString(b);
  const envB = try Env.open(pathB, .{});
  defer envB.close();
  _ = try lmdb.compareEntries(K, V, envA, envB, .{ .log = stdout });

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

var pathBuffer: [4096]u8 = undefined;
pub fn getCString(path: []const u8) [:0]u8 {
  std.mem.copy(u8, &pathBuffer, path);
  pathBuffer[path.len] = 0;
  return pathBuffer[0..path.len :0];
}