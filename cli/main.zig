const std = @import("std");
const assert = std.debug.assert;
const hex = std.fmt.fmtSliceHexLower;
const Sha256 = std.crypto.hash.sha2.Sha256;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("./utils.zig");

const allocator = std.heap.c_allocator;

// var verboseOption = cli.Option{
//     .long_name = "verbose",
//     .short_alias = 'v',
//     .help = "print debugging log to stdout",
//     .value = cli.OptionValue{ .bool = false },
// };

var iotaOption = cli.Option{
    .long_name = "iota",
    .help = "initialize the tree with hashes of the first iota positive integers as sample data",
    .value = cli.OptionValue{ .int = 0 },
};

// var levelOption = cli.Option{
//   .long_name = "level",
//   .short_alias = 'l',
//   .help = "level within the tree (use -1 for the root)",
//   .value = cli.OptionValue{ .int = -1 },
//   .required = false,
// };

// var depthOption = cli.Option{
//   .long_name = "depth",
//   .short_alias = 'd',
//   .help = "number of levels to print",
//   .value = cli.OptionValue{ .int = 1 },
//   .required = false,
// };

var degreeOption = cli.Option{
  .long_name = "degree",
  .short_alias = 'd',
  .help = "target fanout degree",
  .value = cli.OptionValue{ .int = 32 },
  .required = false,
};

var app = &cli.Command{
    .name = "okra",
    .help = "okra is a deterministic pseudo-random merkle tree built on LMDB",
    .subcommands = &.{
        &cli.Command{
            .name = "cat",
            .help = "print the key/value entries to stdout",
            .options = &.{ },
            .action = cat,
        },
        &cli.Command{
            .name = "stat",
            .help = "print metadata",
            .options = &.{ },
            .action = stat,
        },
        &cli.Command{
            .name = "ls",
            .help = "print the tree structure",
            .options = &.{ &degreeOption },
            .action = ls,
        },
        &cli.Command{
            .name = "init",
            .help = "initialize an empty database",
            .options = &.{ &iotaOption, &degreeOption },
            .action = init,
        },
        // &cli.Command{
        //   .name = "insert",
        //   .help = "insert a new leaf",
        //   .options = &.{ &pathOption, &verboseOption },
        //   .action = insert,
        // },
        // &cli.Command{
        //   .name = "rebuild",
        //   .help = "rebuild the tree from the leaf layer",
        //   .options = &.{ &pathOption },
        //   .action = rebuild,
        // },
        &cli.Command{
          .name = "internal",
          .help = "interact with the underlying LMDB database",
          .subcommands = &.{
            &cli.Command{
              .name = "cat",
              .help = "print the entries of the database to stdout",
              .options = &.{ },
              .action = internalCat,
            },
            // &cli.Command{
            //   .name = "get",
            //   .help = "get the value for a key",
            //   .description = "okra internal get [KEY]\n[KEY] - hex-encoded key",
            //   .options = &.{ &pathOption },
            //   .action = internalGet,
            // },
            // &cli.Command{
            //   .name = "set",
            //   .help = "set a key/value entry",
            //   .description = "okra internal set [KEY] [VALUE]\n[KEY] - hex-encoded key\n[VALUE] - hex-encoded value",
            //   .options = &.{ &pathOption },
            //   .action = internalSet,
            // },
            // &cli.Command{
            //   .name = "delete",
            //   .help = "delete a key",
            //   .description = "okra internal delete [KEY]\n[KEY] - hex-encoded key",
            //   .options = &.{ &pathOption },
            //   .action = internalDelete,
            // },
            // &cli.Command{
            //   .name = "diff",
            //   .help = "print the diff between two databases",
            //   .description = "okra internal diff [A] [B]\n[A] - path to database file\n[B] - path to database file",
            //   .options = &.{ &aOption, &bOption },
            //   .action = internalDiff,
            // },
          }
        }
    },
};

fn cat(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path required", .{});
    }

    const path = try utils.resolvePath(allocator, std.fs.cwd(), args[0]);
    defer allocator.free(path);

    try std.fs.accessAbsoluteZ(path, .{ .mode = .read_only });

    const stdout = std.io.getStdOut().writer();

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    var skip_list_cursor = try okra.SkipListCursor.open(allocator, env, true);
    defer skip_list_cursor.abort();

    try skip_list_cursor.goToNode(0, &[_]u8 {});
    while (try skip_list_cursor.goToNext()) |key| {
        const value = try skip_list_cursor.getCurrentValue();
        try stdout.print("{s} <- {s}\n", .{ hex(value), hex(key) });
    }
}

fn stat(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path required", .{});
    }

    const path = try utils.resolvePath(allocator, std.fs.cwd(), args[0]);
    defer allocator.free(path);

    const stdout = std.io.getStdOut().writer();

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, true);
    defer txn.abort();
    if (try okra.getMetadata(txn)) |metadata| {
        try stdout.print("degree: {d}\n", .{ metadata.degree });
        try stdout.print("variant: {any}\n", .{ metadata.variant });
        try stdout.print("height: {d}\n", .{ metadata.height });
    } else {
        return error.InvalidDatabase;
    }
}

fn ls(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path required", .{});
    }

    const path = try utils.resolvePath(allocator, std.fs.cwd(), args[0]);
    defer allocator.free(path);

    const stdout = std.io.getStdOut().writer();

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();
    try okra.printTree(allocator, env, stdout, .{ .compact = true });
}

fn init(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path required", .{});
    }

    const path = try utils.resolvePath(allocator, std.fs.cwd(), args[0]);
    defer allocator.free(path);

    const iota = iotaOption.value.int orelse unreachable;
    if (iota <= 0) {
        fail("iota must be a positive integer", .{});
    } else if (iota > 0xFFFF) {
        fail("iota must be less than 65536", .{});
    }

    const degree = degreeOption.value.int orelse unreachable;
    if (degree < 0) {
        fail("degree must be a non-negative integer", .{});
    } else if (degree > 0xFF) {
        fail("iota must be less than 256", .{});
    }

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    var builder = try okra.Builder.init(env, .{ .degree = @intCast(u8, degree) });
    errdefer builder.abort();

    var key: [2]u8 = undefined;
    var value: [32]u8 = undefined;

    var i: i32 = 0;
    while (i < iota) : (i += 1) {
        std.mem.writeIntBig(u16, &key, @intCast(u16, i));
        Sha256.hash(&key, &value, .{});
        try builder.set(&key, &value);
    }

    try builder.commit();
}

// fn insert(args: []const []const u8) !void {
//     const path = pathOption.value.string orelse unreachable;
//     const verbose = verboseOption.value.bool;

//     if (args.len == 0) {
//         fail("missing leaf argument", .{});
//     } else if (args.len == 1) {
//         fail("missing hash argument", .{});
//     } else if (args.len > 2) {
//         fail("too many arguments", .{});
//     }

//     const leafArg = args[0];
//     const hashArg = args[1];

//     if (leafArg.len != 2 * X) {
//         fail("invalid leaf size - expected exactly {d} hex bytes", .{ X });
//     } else if (hashArg.len != 2 * V) {
//         fail("invalid hash size - expected exactly {d} hex bytes", .{ V });
//     }

//     var leaf = [_]u8{ 0 } ** X;
//     var hash = [_]u8{ 0 } ** V;

//     _ = try std.fmt.hexToBytes(&leaf, leafArg);
//     _ = try std.fmt.hexToBytes(&hash, hashArg);

//     const log = if (verbose) std.io.getStdOut().writer() else null;
//     var tree: Tree = undefined;
//     try tree.init(allocator, getCString(path), .{ .log = log });
//     defer tree.close();

//     try tree.insert(&leaf, &hash);
// }

// fn rebuild(args: []const []const u8) !void {
//     const path = pathOption.value.string orelse unreachable;
//     if (args.len > 0) {
//         fail("too many arguments", .{});
//     }

//     try razeTree(path);

//     var builder = try Builder.init(getCString(path), .{});
//     _ = try builder.finalize(null);
//     const stdout = std.io.getStdOut().writer();
//     try stdout.print("Successfully rebuilt {s}\n", .{ path });
// }

// fn razeTree(path: []const u8) !void {
//     var env = try Env.open(getCString(path), .{});
//     defer env.close();

//     var txn = try Txn.open(env, false);
//     errdefer txn.abort();

//     const dbi = try txn.openDBI();

//     var cursor = try Cursor.open(txn, dbi);

//     const firstKey = Tree.createKey(1, null);
//     try cursor.goToKey(&firstKey);
//     try cursor.deleteCurrentKey();
//     while (try cursor.goToNext()) |_| try cursor.deleteCurrentKey();

//     cursor.close();
//     try txn.commit();
// }

fn internalCat(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path required", .{});
    }

    const path = try utils.resolvePath(allocator, std.fs.cwd(), args[0]);
    defer allocator.free(path);

    const stdout = std.io.getStdOut().writer();

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, true);
    defer txn.abort();

    const cursor = try lmdb.Cursor.open(txn);
    defer cursor.close();

    var entry = try cursor.goToFirst();
    while (entry) |key| : (entry = try cursor.goToNext()) {
        const value = try cursor.getCurrentValue();
        try stdout.print("{s} <- {s}\n", .{ hex(value), hex(key) });
    }
}

// fn internalSet(args: []const []const u8) !void {
//     const path = pathOption.value.string orelse unreachable;

//     if (args.len == 0) {
//         fail("missing key argument", .{});
//     } else if (args.len == 1) {
//         fail("missing value argument", .{});
//     } else if (args.len > 2) {
//         fail("too many arguments", .{});
//     }

//     const keyArg = args[0];
//     const valueArg = args[1];

//     if (keyArg.len != 2 * K) {
//         fail("invalid key size - expected exactly {d} hex bytes", .{ K });
//     } else if (valueArg.len != 2 * V) {
//         fail("invalid value size - expected exactly {d} hex bytes", .{ V });
//     }

//     var env = try Env.open(getCString(path), .{});
//     defer env.close();
//     var txn = try Txn.open(env, false);
//     errdefer txn.abort();
//     const dbi = try txn.openDBI();

//     var value = [_]u8{ 0 } ** V;
//     _ = try std.fmt.hexToBytes(&value, valueArg);

//     var key = [_]u8{ 0 } ** K;
//     _ = try std.fmt.hexToBytes(&key, keyArg);

//     try txn.set(dbi, &key, &value);
//     try txn.commit();
// }

// fn internalGet(args: []const []const u8) !void {
//     const path = pathOption.value.string orelse unreachable;

//     if (args.len == 0) {
//         fail("key argument required", .{});
//     } else if (args.len > 1) {
//         fail("too many arguments", .{});
//     }

//     const keyArg = args[0];
//     if (keyArg.len != 2 * K) {
//         fail("invalid key size - expected exactly {d} hex bytes", .{ K });
//     }

//     const stdout = std.io.getStdOut().writer();

//     var env = try Env.open(getCString(path), .{});
//     defer env.close();
//     var txn = try Txn.open(env, true);
//     defer txn.abort();
//     const dbi = try txn.openDBI();

//     var key = [_]u8{ 0 } ** K;
//     _ = try std.fmt.hexToBytes(&key, keyArg);

//     if (try txn.get(dbi, &key)) |value| {
//         try stdout.print("{s}\n", .{ hex(value) });
//     }
// }

// fn internalDelete(args: []const []const u8) !void {
//     const path = pathOption.value.string orelse unreachable;

//     if (args.len == 0) {
//         fail("key argument required", .{});
//     } else if (args.len > 1) {
//         fail("too many arguments", .{});
//     }

//     const keyArg = args[0];
//     if (keyArg.len != 2 * K) {
//         fail("invalid key size - expected exactly {d} hex bytes", .{ K });
//     }

//     var env = try Env.open(getCString(path), .{});
//     defer env.close();
//     var txn = try Txn.open(env, false);
//     errdefer txn.abort();
//     const dbi = try txn.openDBI();
    
//     var key = [_]u8{ 0 } ** K;
//     _ = try std.fmt.hexToBytes(&key, keyArg);
//     try txn.delete(dbi, &key);
//     try txn.commit();
// }

// fn internalDiff(args: []const []const u8) !void {
//     const a = aOption.value.string orelse unreachable;
//     const b = bOption.value.string orelse unreachable;

//     if (args.len > 0) {
//         fail("too many arguments", .{});
//     }

//     const stdout = std.io.getStdOut().writer();

//     const pathA = getCString(a);
//     const envA = try Env.open(pathA, .{});
//     defer envA.close();
//     const pathB = getCString(b);
//     const envB = try Env.open(pathB, .{});
//     defer envB.close();
//     _ = try lmdb.compareEntries(K, V, envA, envB, .{ .log = stdout });
// }

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

// var path_buffer: [4096]u8 = undefined;
// pub fn getCString(path: []const u8) [:0]u8 {
//     std.mem.copy(u8, &path_buffer, path);
//     path_buffer[path.len] = 0;
//     return path_buffer[0..path.len :0];
// }