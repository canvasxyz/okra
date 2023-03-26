const std = @import("std");
const assert = std.debug.assert;
const hex = std.fmt.fmtSliceHexLower;
const Sha256 = std.crypto.hash.sha2.Sha256;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("./utils.zig");
const Printer = @import("./printer.zig").Printer;

const allocator = std.heap.c_allocator;

var nameOption = cli.Option{
    .long_name = "name",
    .short_alias = 'n',
    .help = "use a named database instance",
    .value = cli.OptionValue{ .string = null },
    .required = false,
};

var verboseOption = cli.Option{
    .long_name = "verbose",
    .short_alias = 'v',
    .help = "print verbose debugging info to stdout",
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
    .help = "node level (-1 for root)",
    .value = cli.OptionValue{ .int = -1 },
    .required = false,
};

var keyOption = cli.Option{
    .long_name = "key",
    .short_alias = 'k',
    .help = "node key",
    .value = cli.OptionValue{ .string = null },
    .required = false,
};

var encodingOption = cli.Option{
    .long_name = "encoding",
    .short_alias = 'e',
    .help = "\"utf-8\" or \"hex\" (default \"utf-8\")",
    .value = cli.OptionValue{ .string = "utf-8" },
    .required = false,
};

var depthOption = cli.Option{
    .long_name = "depth",
    .short_alias = 'd',
    .help = "tree depth",
    .value = cli.OptionValue{ .int = null },
    .required = false,
};

var padOption = cli.Option{
    .long_name = "pad",
    .short_alias = 'p',
    .help = "align to fixed height",
    .value = cli.OptionValue{ .int = 0 },
    .required = false,
};

fn parseEncoding() utils.Encoding {
    const encoding = encodingOption.value.string orelse unreachable;
    if (std.mem.eql(u8, encoding, "utf-8")) {
        return utils.Encoding.utf8;
    } else if (std.mem.eql(u8, encoding, "hex")) {
        return utils.Encoding.hex;
    } else {
        fail("invalid encoding", .{});
    }
}

var app = &cli.Command{
    .name = "okra",
    .help = "okra is a deterministic pseudo-random merkle tree built on LMDB",
    .subcommands = &.{
        &cli.Command{
            .name = "cat",
            .help = "print the key/value entries to stdout",
            .options = &.{ &nameOption, &encodingOption },
            .action = cat,
        },
        &cli.Command{
            .name = "ls",
            .help = "list the children of an internal node",
            .options = &.{ &nameOption, &encodingOption, &levelOption, &keyOption },
            .action = ls,
        },
        &cli.Command{
            .name = "tree",
            .help = "print the tree structure",
            .options = &.{ &nameOption, &encodingOption, &levelOption, &keyOption, &depthOption, &padOption },
            .action = tree,
        },
        &cli.Command{
            .name = "init",
            .help = "initialize an empty database",
            .options = &.{ &nameOption, &iotaOption },
            .action = init,
        },
        &cli.Command{
            .name = "set",
            .help = "set a key/value entry",
            .options = &.{ &nameOption, &encodingOption, &verboseOption },
            .action = set,
        },
        &cli.Command{
            .name = "get",
            .help = "get a key/value entry",
            .options = &.{ &nameOption, &encodingOption },
            .action = get,
        },
        &cli.Command{
            .name = "delete",
            .help = "delete a key/value entry",
            .options = &.{ &nameOption, &encodingOption, &verboseOption },
            .action = delete,
        },
        &cli.Command{
            .name = "hash",
            .help = "compute the hash of a key/value entry",
            .options = &.{&encodingOption},
            .action = hash,
        },
    },
};

fn cat(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path argument required", .{});
    }

    const encoding = parseEncoding();

    const stdout = std.io.getStdOut().writer();

    const path = try utils.resolvePath(std.fs.cwd(), args[0]);
    var t = try okra.Tree.open(allocator, path, .{});
    defer t.close();

    var txn = try okra.Transaction.open(allocator, &t, .{ .mode = .ReadOnly });
    defer txn.abort();

    var cursor = try okra.Cursor.open(allocator, &txn);
    defer cursor.close();

    _ = try cursor.goToNode(0, null);
    while (try cursor.goToNext(0)) |node| {
        switch (encoding) {
            .utf8 => try stdout.print("{s}\t{s}\n", .{ node.key.?, node.value.? }),
            .hex => try stdout.print("{s}\t{s}\n", .{ hex(node.key.?), hex(node.value.?) }),
        }
    }
}

fn ls(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path argument required", .{});
    }

    const encoding = parseEncoding();

    var key_buffer = std.ArrayList(u8).init(allocator);
    defer key_buffer.deinit();
    if (keyOption.value.string) |key| {
        switch (encoding) {
            .hex => {
                if (key.len % 2 == 0) {
                    try key_buffer.resize(key.len / 2);
                    _ = try std.fmt.hexToBytes(key_buffer.items, key);
                } else {
                    fail("invalid hex input", .{});
                }
            },
            .utf8 => {
                try key_buffer.resize(key.len);
                std.mem.copy(u8, key_buffer.items, key);
            },
        }
    }

    const level = levelOption.value.int orelse unreachable;
    if (level == -1) {
        if (key_buffer.items.len != 0) {
            fail("the root node's key is the empty string", .{});
        }
    } else if (level < 0) {
        fail("level must be -1 or a non-negative integer", .{});
    } else if (level >= 0xFF) {
        fail("level must be less than 254", .{});
    }

    const stdout = std.io.getStdOut().writer();

    const path = try utils.resolvePath(std.fs.cwd(), args[0]);
    var t = try okra.Tree.open(allocator, path, .{});
    defer t.close();

    var txn = try okra.Transaction.open(allocator, &t, .{ .mode = .ReadOnly });
    defer txn.abort();

    var cursor = try okra.Cursor.open(allocator, &txn);
    defer cursor.close();

    const root = if (level == -1)
        try cursor.goToRoot()
    else
        try cursor.goToNode(@intCast(u8, level), key_buffer.items);

    try stdout.print("level | {s: <32} | key\n", .{"hash"});
    try stdout.print("----- | {s:-<32} | {s:-<32}\n", .{ "", "" });
    try printNode(stdout, root, encoding);

    if (root.level > 0) {
        try stdout.print("----- | {s:-<32} | {s:-<32}\n", .{ "", "" });
        const first_child = try cursor.goToNode(root.level - 1, root.key);
        try printNode(stdout, first_child, encoding);
        while (try cursor.goToNext(root.level - 1)) |next|
            try printNode(stdout, next, encoding);
    }
}

fn printNode(writer: std.fs.File.Writer, node: okra.Node, encoding: utils.Encoding) !void {
    if (node.key) |key|
        switch (encoding) {
            .hex => try writer.print("{d: >5} | {s} | {s}\n", .{ node.level, hex(node.hash), hex(key) }),
            .utf8 => try writer.print("{d: >5} | {s} | {s}\n", .{ node.level, hex(node.hash), key }),
        }
    else {
        try writer.print("{d: >5} | {s} |\n", .{ node.level, hex(node.hash) });
    }
}

fn tree(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path argument required", .{});
    }

    const encoding = parseEncoding();

    var key_buffer = std.ArrayList(u8).init(allocator);
    defer key_buffer.deinit();
    if (keyOption.value.string) |key| {
        switch (encoding) {
            .hex => {
                if (key.len % 2 == 0) {
                    try key_buffer.resize(key.len / 2);
                    _ = try std.fmt.hexToBytes(key_buffer.items, key);
                } else {
                    fail("invalid hex input", .{});
                }
            },
            .utf8 => {
                try key_buffer.resize(key.len);
                std.mem.copy(u8, key_buffer.items, key);
            },
        }
    }

    const level = levelOption.value.int orelse unreachable;
    if (level == -1) {
        if (key_buffer.items.len != 0) {
            fail("the root node's key is the empty string", .{});
        }
    } else if (level < 0) {
        fail("level must be -1 or a non-negative integer", .{});
    } else if (level >= 0xFF) {
        fail("level must be less than 255", .{});
    }

    var depth: ?u8 = null;
    if (depthOption.value.int) |value| {
        if (value < 0) {
            fail("depth must be a non-negative integer", .{});
        } else if (value > 0xFF) {
            fail("depth must be less than 256", .{});
        } else {
            depth = @intCast(u8, value);
        }
    }

    var pad: u8 = 0;
    if (padOption.value.int) |value| {
        if (value < 0) {
            fail("pad must be a non-negative integer", .{});
        } else if (value > 0xFF) {
            fail("pad must be less than 256", .{});
        } else {
            pad = @intCast(u8, value);
        }
    }

    var treeOptions = okra.Tree.Options{};
    var txnOptions = okra.Transaction.Options{ .mode = .ReadOnly };

    var dbi = std.ArrayList(u8).init(allocator);
    defer dbi.deinit();
    if (nameOption.value.string) |name| {
        try dbi.resize(name.len + 1);
        std.mem.copy(u8, dbi.items[0..name.len], name);
        dbi.items[name.len] = 0;

        treeOptions.dbs = &.{dbi.items[0..name.len :0]};
    }

    const path = try utils.resolvePath(std.fs.cwd(), args[0]);
    var t = try okra.Tree.open(allocator, path, treeOptions);
    defer t.close();

    var txn = try okra.Transaction.open(allocator, &t, txnOptions);
    defer txn.abort();

    var printer = try Printer.init(allocator, txn, encoding);
    defer printer.deinit();
    try printer.printRoot(pad, depth);
}

fn get(args: []const []const u8) !void {
    if (args.len > 2) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path argument required", .{});
    } else if (args.len == 1) {
        fail("key argument required", .{});
    }

    const encoding = parseEncoding();

    var key_buffer = std.ArrayList(u8).init(allocator);
    defer key_buffer.deinit();

    switch (encoding) {
        .hex => {
            if (args[1].len % 2 == 0) {
                try key_buffer.resize(args[1].len / 2);
                _ = try std.fmt.hexToBytes(key_buffer.items, args[1]);
            } else {
                fail("invalid hex input", .{});
            }
        },
        .utf8 => {
            try key_buffer.resize(args[1].len);
            std.mem.copy(u8, key_buffer.items, args[1]);
        },
    }

    const path = try utils.resolvePath(std.fs.cwd(), args[0]);

    var treeOptions = okra.Tree.Options{};
    var txnOptions = okra.Transaction.Options{ .mode = .ReadOnly };

    var dbi = std.ArrayList(u8).init(allocator);
    defer dbi.deinit();
    if (nameOption.value.string) |name| {
        try dbi.resize(name.len + 1);
        std.mem.copy(u8, dbi.items[0..name.len], name);
        dbi.items[name.len] = 0;

        treeOptions.dbs = &.{dbi.items[0..name.len :0]};
    }

    var t = try okra.Tree.open(allocator, path, treeOptions);
    defer t.close();

    var txn = try okra.Transaction.open(allocator, &t, txnOptions);
    defer txn.abort();

    const value = try txn.get(key_buffer.items) orelse fail("KeyNotFound", .{});

    const stdout = std.io.getStdOut().writer();
    switch (encoding) {
        .hex => {
            try stdout.print("{s}\n", .{hex(value)});
        },
        .utf8 => {
            try stdout.print("{s}\n", .{value});
        },
    }
}

fn set(args: []const []const u8) !void {
    if (args.len > 3) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path argument required", .{});
    } else if (args.len == 1) {
        fail("key argument required", .{});
    } else if (args.len == 2) {
        fail("value argument required", .{});
    }

    const encoding = parseEncoding();

    var key_buffer = std.ArrayList(u8).init(allocator);
    defer key_buffer.deinit();

    var value_buffer = std.ArrayList(u8).init(allocator);
    defer value_buffer.deinit();

    switch (encoding) {
        .hex => {
            if (args[1].len % 2 == 0) {
                try key_buffer.resize(args[1].len / 2);
                _ = try std.fmt.hexToBytes(key_buffer.items, args[1]);
            } else {
                fail("invalid hex input", .{});
            }

            if (args[2].len % 2 == 0) {
                try value_buffer.resize(args[2].len / 2);
                _ = try std.fmt.hexToBytes(value_buffer.items, args[2]);
            } else {
                fail("invalid hex input", .{});
            }
        },
        .utf8 => {
            try key_buffer.resize(args[1].len);
            std.mem.copy(u8, key_buffer.items, args[1]);

            try value_buffer.resize(args[2].len);
            std.mem.copy(u8, value_buffer.items, args[2]);
        },
    }

    var treeOptions = okra.Tree.Options{};
    var txnOptions = okra.Transaction.Options{ .mode = .ReadWrite };

    var dbi = std.ArrayList(u8).init(allocator);
    defer dbi.deinit();
    if (nameOption.value.string) |name| {
        try dbi.resize(name.len + 1);
        std.mem.copy(u8, dbi.items[0..name.len], name);
        dbi.items[name.len] = 0;

        treeOptions.dbs = &.{dbi.items[0..name.len :0]};
    }

    if (verboseOption.value.bool) {
        txnOptions.log = std.io.getStdOut().writer();
    }

    const path = try utils.resolvePath(std.fs.cwd(), args[0]);
    var t = try okra.Tree.open(allocator, path, treeOptions);
    defer t.close();

    var txn = try okra.Transaction.open(allocator, &t, txnOptions);
    errdefer txn.abort();

    try txn.set(key_buffer.items, value_buffer.items);
    try txn.commit();
}

fn delete(args: []const []const u8) !void {
    if (args.len > 2) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path argument required", .{});
    } else if (args.len == 1) {
        fail("key argument required", .{});
    }

    const encoding = parseEncoding();

    var key_buffer = std.ArrayList(u8).init(allocator);
    defer key_buffer.deinit();

    switch (encoding) {
        .hex => {
            if (args[1].len % 2 == 0) {
                try key_buffer.resize(args[1].len / 2);
                _ = try std.fmt.hexToBytes(key_buffer.items, args[1]);
            } else {
                fail("invalid hex input", .{});
            }
        },
        .utf8 => {
            try key_buffer.resize(args[1].len);
            std.mem.copy(u8, key_buffer.items, args[1]);
        },
    }

    var treeOptions = okra.Tree.Options{};
    var txnOptions = okra.Transaction.Options{ .mode = .ReadWrite };

    var dbi = std.ArrayList(u8).init(allocator);
    defer dbi.deinit();
    if (nameOption.value.string) |name| {
        try dbi.resize(name.len + 1);
        std.mem.copy(u8, dbi.items[0..name.len], name);
        dbi.items[name.len] = 0;

        treeOptions.dbs = &.{dbi.items[0..name.len :0]};
    }

    if (verboseOption.value.bool) {
        txnOptions.log = std.io.getStdOut().writer();
    }

    const path = try utils.resolvePath(std.fs.cwd(), args[0]);
    var t = try okra.Tree.open(allocator, path, treeOptions);
    defer t.close();

    var txn = try okra.Transaction.open(allocator, &t, txnOptions);
    errdefer txn.abort();

    try txn.delete(key_buffer.items);
    try txn.commit();
}

fn init(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path argument required", .{});
    }

    const iota = iotaOption.value.int orelse unreachable;
    if (iota < 0) {
        fail("iota must be a non-negative integer", .{});
    } else if (iota > 0xFFFF) {
        fail("iota must be less than 65536", .{});
    }

    var key: [2]u8 = undefined;
    var value: [32]u8 = undefined;

    const path = try utils.resolvePath(std.fs.cwd(), args[0]);
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

fn hash(args: []const []const u8) !void {
    if (args.len > 2) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("key argument required", .{});
    } else if (args.len == 1) {
        fail("value argument required", .{});
    }

    var key_buffer = std.ArrayList(u8).init(allocator);
    defer key_buffer.deinit();

    var value_buffer = std.ArrayList(u8).init(allocator);
    defer value_buffer.deinit();

    const encoding = parseEncoding();
    try parseBuffer(args[0], &key_buffer, encoding);
    try parseBuffer(args[1], &value_buffer, encoding);

    var hash_buffer: [okra.K]u8 = undefined;
    okra.hashEntry(key_buffer.items, value_buffer.items, &hash_buffer);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{hex(&hash_buffer)});
}

fn parseBuffer(arg: []const u8, buffer: *std.ArrayList(u8), encoding: utils.Encoding) !void {
    switch (encoding) {
        .hex => {
            if (arg.len % 2 == 0) {
                try buffer.resize(arg.len / 2);
                _ = try std.fmt.hexToBytes(buffer.items, arg);
            } else {
                fail("invalid hex input", .{});
            }
        },
        .utf8 => {
            try buffer.resize(arg.len);
            std.mem.copy(u8, buffer.items, arg);
        },
    }
}

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
