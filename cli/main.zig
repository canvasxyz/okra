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

var levelOption = cli.Option{
    .long_name = "level",
    .short_alias = 'l',
    .help = "node level (-1 for root)",
    .value = cli.OptionValue{ .int = -1 },
    .required = false,
};

var keyOption = cli.Option{
    .long_name = "key",
    .short_alias = 'k',
    .help = "node key",
    .value = cli.OptionValue{ .string = "" },
    .required = false,
};

var encodingOption = cli.Option{
    .long_name = "encoding",
    .short_alias = 'e',
    .help = "encoding (\"utf-8\" or \"hex\")",
    .value = cli.OptionValue{ .string = "utf-8" },
    .required = false,
};

const Encoding = enum { utf8, hex };

fn parseEncoding() Encoding {
    const encoding = encodingOption.value.string orelse unreachable;
    if (std.mem.eql(u8, encoding, "utf-8")) {
        return Encoding.utf8;
    } else if (std.mem.eql(u8, encoding, "hex")) {
        return Encoding.hex;
    } else {
        fail("invalid encoding", .{});
    }
}

// fn parseKey(encoding: Encoding) ?[]const u8 {
//     const key = keyOption.value.string orelse unreachable;
//     return if (key.len > 0) switch (encoding) {
//         .utf8 => key,
//         .hex => {
//             if (key.len % 2 == 1) {
//                 fail("invalid hex input", .{});
//             }
//             const buffer = allocator.alloc(u8, key.len / 2) catch unreachable;
//             return std.fmt.hexToBytes(buffer, key) catch unreachable;
//         },
//     } else null;
// }

var app = &cli.Command{
    .name = "okra",
    .help = "okra is a deterministic pseudo-random merkle tree built on LMDB",
    .subcommands = &.{
        &cli.Command{
            .name = "cat",
            .help = "print the key/value entries to stdout",
            .options = &.{&encodingOption},
            .action = cat,
        },
        &cli.Command{
            .name = "ls",
            .help = "print the tree structure",
            .options = &.{ &encodingOption, &levelOption, &keyOption },
            .action = ls,
        },
        &cli.Command{
            .name = "init",
            .help = "initialize an empty database",
            .options = &.{&iotaOption},
            .action = init,
        },
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
                    .options = &.{},
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
            },
        },
    },
};

fn cat(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path required", .{});
    }

    const encoding = parseEncoding();

    const path = try utils.resolvePath(allocator, std.fs.cwd(), args[0]);
    defer allocator.free(path);

    try std.fs.accessAbsoluteZ(path, .{ .mode = .read_only });

    const stdout = std.io.getStdOut().writer();

    const tree = try okra.Tree.open(allocator, path, .{});
    defer tree.close();

    const txn = try okra.Transaction.open(allocator, tree, .{ .read_only = true });
    defer txn.abort();

    const iter = try okra.Iterator.open(allocator, txn);
    defer iter.close();

    var entry = try iter.goToFirst();
    while (entry) |e| : (entry = try iter.goToNext()) {
        switch (encoding) {
            .utf8 => try stdout.print("{s}\t{s}\n", .{ e.key, e.value }),
            .hex => try stdout.print("{s}\t{s}\n", .{ hex(e.key), hex(e.value) }),
        }
    }
}

const hashSeparator = "  " ** okra.K;

fn printNode(writer: std.fs.File.Writer, node: okra.Cursor.Node, encoding: Encoding) !void {
    if (node.key) |key|
        switch (encoding) {
            .hex => try writer.print("{d: >5} | {s} | {s}\n", .{ node.level, hex(node.hash), hex(key) }),
            .utf8 => try writer.print("{d: >5} | {s} | {s}\n", .{ node.level, hex(node.hash), key }),
        }
    else {
        try writer.print("{d: >5} | {s} |\n", .{ node.level, hex(node.hash) });
    }
}

fn ls(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path required", .{});
    }

    const encoding = parseEncoding();

    const key = keyOption.value.string orelse unreachable;
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    switch (encoding) {
        .hex => {
            if (key.len % 2 == 0) {
                try buffer.resize(key.len / 2);
                _ = try std.fmt.hexToBytes(buffer.items, key);
            } else {
                fail("invalid hex input", .{});
            }
        },
        .utf8 => {
            try buffer.resize(key.len);
            std.mem.copy(u8, buffer.items, key);
        },
    }

    const level = levelOption.value.int orelse unreachable;
    if (level == -1) {
        if (key.len != 0) {
            fail("the root node's key is the empty string", .{});
        }
    } else if (level < 0) {
        fail("level must be -1 or a non-negative integer", .{});
    } else if (level >= 0xFF) {
        fail("level must be less than 254", .{});
    }

    const path = try utils.resolvePath(allocator, std.fs.cwd(), args[0]);
    defer allocator.free(path);

    try std.fs.accessAbsoluteZ(path, .{ .mode = .read_only });

    const stdout = std.io.getStdOut().writer();

    const tree = try okra.Tree.open(allocator, path, .{});
    defer tree.close();

    const txn = try okra.Transaction.open(allocator, tree, .{ .read_only = true });
    defer txn.abort();

    const cursor = try okra.Cursor.open(allocator, txn);
    defer cursor.close();

    try stdout.print("level | {s: <32} | key\n", .{"hash"});
    try stdout.print("----- | {s:-<32} | {s:-<32}\n", .{ "", "" });

    const root = if (level == -1)
        try cursor.goToRoot()
    else
        try cursor.goToNode(@intCast(u8, level), buffer.items);

    try printNode(stdout, root, encoding);

    if (root.level > 0) {
        try stdout.print("----- | {s:-<32} | {s:-<32}\n", .{ "", "" });
        const first_child = try cursor.goToNode(root.level - 1, root.key);
        try printNode(stdout, first_child, encoding);
        while (try cursor.goToNext()) |next| try printNode(stdout, next, encoding);
    }
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
    if (iota < 0) {
        fail("iota must be a non-negative integer", .{});
    } else if (iota > 0xFFFF) {
        fail("iota must be less than 65536", .{});
    }

    var key: [2]u8 = undefined;
    var value: [32]u8 = undefined;

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    {
        var builder = try okra.Builder.open(allocator, env, .{});
        errdefer builder.abort();

        var i: u16 = 0;
        while (i < iota) : (i += 1) {
            std.mem.writeIntBig(u16, &key, i);
            Sha256.hash(&key, &value, .{});
            try builder.set(&key, &value);
        }

        try builder.commit();
    }
}

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

    try std.fs.accessAbsoluteZ(path, .{ .mode = std.fs.File.OpenMode.read_only });

    const stdout = std.io.getStdOut().writer();

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .read_only = true });
    defer txn.abort();

    const cursor = try lmdb.Cursor.open(txn);
    defer cursor.close();

    var entry = try cursor.goToFirst();
    while (entry) |key| : (entry = try cursor.goToNext()) {
        const value = try cursor.getCurrentValue();
        try stdout.print("{s}\t{s}\n", .{ hex(key), hex(value) });
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
