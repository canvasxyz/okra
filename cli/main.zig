const std = @import("std");
const assert = std.debug.assert;
const hex = std.fmt.fmtSliceHexLower;
const Sha256 = std.crypto.hash.sha2.Sha256;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("./utils.zig");
const Printer = @import("./printer.zig");

const allocator = std.heap.c_allocator;

var name_option = cli.Option{
    .long_name = "name",
    .short_alias = 'n',
    .help = "use a named database instance",
    .value = cli.OptionValue{ .string = null },
    .required = false,
};

var verbose_option = cli.Option{
    .long_name = "verbose",
    .short_alias = 'v',
    .help = "print verbose debugging info to stdout",
    .value = cli.OptionValue{ .bool = false },
};

var iota_option = cli.Option{
    .long_name = "iota",
    .help = "initialize the tree with hashes of the first iota positive integers as sample data",
    .value = cli.OptionValue{ .int = 0 },
};

var max_dbs_option = cli.Option{
    .long_name = "dbs",
    .help = "maximum number of named databases to support",
    .value = cli.OptionValue{ .int = 0 },
};

var level_option = cli.Option{
    .long_name = "level",
    .short_alias = 'l',
    .help = "node level (-1 for root)",
    .value = cli.OptionValue{ .int = -1 },
    .required = false,
};

var key_option = cli.Option{
    .long_name = "key",
    .short_alias = 'k',
    .help = "node key",
    .value = cli.OptionValue{ .string = null },
    .required = false,
};

var encoding_option = cli.Option{
    .long_name = "encoding",
    .short_alias = 'e',
    .help = "\"utf-8\" or \"hex\" (default \"utf-8\")",
    .value = cli.OptionValue{ .string = "hex" },
    .required = false,
};

var depth_option = cli.Option{
    .long_name = "depth",
    .short_alias = 'd',
    .help = "tree depth",
    .value = cli.OptionValue{ .int = null },
    .required = false,
};

var height_option = cli.Option{
    .long_name = "height",
    .short_alias = 'h',
    .help = "align to fixed height",
    .value = cli.OptionValue{ .int = null },
    .required = false,
};

var trace_option = cli.Option{
    .long_name = "trace",
    .short_alias = 't',
    .help = "trace the updated hashes",
    .value = cli.OptionValue{ .bool = false },
    .required = false,
};

var app = &cli.App{
    .name = "okra",
    .description = "okra is a deterministic pseudo-random merkle tree built on LMDB",
    .subcommands = &.{
        &cli.Command{
            .name = "cat",
            .help = "print the key/value entries to stdout",
            .options = &.{ &name_option, &encoding_option },
            .action = cat,
        },
        &cli.Command{
            .name = "ls",
            .help = "list the children of an internal node",
            .options = &.{ &name_option, &encoding_option, &level_option, &key_option },
            .action = ls,
        },
        &cli.Command{
            .name = "tree",
            .help = "print the tree structure",
            .options = &.{ &name_option, &encoding_option, &level_option, &key_option, &depth_option, &height_option },
            .action = printTree,
        },
        &cli.Command{
            .name = "init",
            .help = "initialize an empty database",
            .options = &.{&iota_option},
            .action = init,
        },
        &cli.Command{
            .name = "stat",
            .help = "print environment metadata",
            .options = &.{&name_option},
            .action = init,
        },
        &cli.Command{
            .name = "get",
            .help = "get a key/value entry",
            .options = &.{ &name_option, &encoding_option },
            .action = get,
        },
        &cli.Command{
            .name = "set",
            .help = "set a key/value entry",
            .options = &.{ &name_option, &encoding_option, &verbose_option, &trace_option, &depth_option, &height_option },
            .action = set,
        },
        &cli.Command{
            .name = "delete",
            .help = "delete a key/value entry",
            .options = &.{ &name_option, &encoding_option, &verbose_option, &trace_option, &depth_option, &height_option },
            .action = delete,
        },
        &cli.Command{
            .name = "hash",
            .help = "compute the hash of a key/value entry",
            .options = &.{&encoding_option},
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

    const path = try lmdb.utils.resolvePath(std.fs.cwd(), args[0]);
    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
    defer txn.abort();

    const db = try lmdb.Database.open(txn, .{});
    var tree = try okra.Tree.open(allocator, db, .{});
    defer tree.close();

    const range = okra.Iterator.Range{
        .level = 0,
        .lower_bound = .{ .key = null, .inclusive = false },
    };

    var iterator = try okra.Iterator.open(allocator, &tree, range);
    defer iterator.close();

    while (try iterator.next()) |node| {
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

    if (key_option.value.string) |key| {
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

    const level = level_option.value.int orelse unreachable;
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

    const path = try lmdb.utils.resolvePath(std.fs.cwd(), args[0]);
    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
    defer txn.abort();

    const db = try lmdb.Database.open(txn, .{});
    var tree = try okra.Tree.open(allocator, db, .{});
    defer tree.close();

    const root = if (level == -1) try tree.getRoot() else try getNode(&tree, @intCast(level), key_buffer.items);

    try stdout.print("level | {s: <32} | key\n", .{"hash"});
    try stdout.print("----- | {s:-<32} | {s:-<32}\n", .{ "", "" });
    try printNode(stdout, root, encoding);

    if (root.level > 0) {
        try stdout.print("----- | {s:-<32} | {s:-<32}\n", .{ "", "" });

        const range = okra.Iterator.Range{
            .level = root.level - 1,
            .lower_bound = .{ .key = root.key, .inclusive = true },
        };

        var iterator = try okra.Iterator.open(allocator, &tree, range);
        defer iterator.close();

        var i: usize = 0;
        while (try iterator.next()) |node| : (i += 1) {
            if (i > 0 and node.isBoundary()) {
                break;
            } else {
                try printNode(stdout, node, encoding);
            }
        }
    }
}

fn getNode(tree: *okra.Tree, level: u8, key: ?[]const u8) !okra.Node {
    return try tree.getNode(level, key) orelse fail("node not found", .{});
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

fn printTree(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path argument required", .{});
    }

    const encoding = parseEncoding();

    var key_buffer = std.ArrayList(u8).init(allocator);
    defer key_buffer.deinit();
    if (key_option.value.string) |key| {
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

    const level = level_option.value.int orelse unreachable;
    if (level == -1) {
        if (key_buffer.items.len != 0) {
            fail("the root node's key is the empty string", .{});
        }
    } else if (level < 0) {
        fail("level must be -1 or a non-negative integer", .{});
    } else if (level >= 0xFF) {
        fail("level must be less than 255", .{});
    }

    const height = parseHeight();
    const depth = parseDepth();

    var dbi = std.ArrayList(u8).init(allocator);
    defer dbi.deinit();
    const name = try parseName(&dbi);

    const path = try lmdb.utils.resolvePath(std.fs.cwd(), args[0]);
    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
    errdefer txn.abort();

    const db = try lmdb.Database.open(txn, .{ .name = name });
    var tree = try okra.Tree.open(allocator, db, .{});
    defer tree.close();

    var printer = try Printer.init(allocator, &tree, encoding, null);
    defer printer.deinit();

    try printer.printRoot(height, depth);
}

fn parseDepth() ?u8 {
    if (depth_option.value.int) |depth| {
        if (depth < 0) {
            fail("depth must be a non-negative integer", .{});
        } else if (depth > 0xFF) {
            fail("depth must be less than 256", .{});
        } else {
            return @as(u8, @intCast(depth));
        }
    } else {
        return null;
    }
}

fn parseHeight() ?u8 {
    if (height_option.value.int) |height| {
        if (height < 0) {
            fail("height must be a non-negative integer", .{});
        } else if (height > 0xFF) {
            fail("height must be less than 256", .{});
        } else {
            return @as(u8, @intCast(height));
        }
    } else {
        return null;
    }
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

    var dbi = std.ArrayList(u8).init(allocator);
    defer dbi.deinit();
    const name = try parseName(&dbi);

    const path = try lmdb.utils.resolvePath(std.fs.cwd(), args[0]);
    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
    errdefer txn.abort();

    const db = try lmdb.Database.open(txn, .{ .name = name });
    var tree = try okra.Tree.open(allocator, db, .{});
    defer tree.close();

    const value = try tree.get(key_buffer.items) orelse fail("KeyNotFound", .{});

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
    try parseKey(&key_buffer);

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

    const height = parseHeight();
    const depth = parseDepth();

    var trace_nodes = okra.NodeList.init(allocator);
    const trace = if (trace_option.value.bool) &trace_nodes else null;

    var dbi = std.ArrayList(u8).init(allocator);
    defer dbi.deinit();
    const name = try parseName(&dbi);

    const log = if (verbose_option.value.bool) std.io.getStdOut().writer() else null;

    const path = try lmdb.utils.resolvePath(std.fs.cwd(), args[0]);
    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
    errdefer txn.abort();

    const db = try lmdb.Database.open(txn, .{ .name = name });
    var tree = try okra.Tree.open(allocator, db, .{ .log = log, .trace = trace });
    defer tree.close();

    try tree.set(key_buffer.items, value_buffer.items);

    if (trace_option.value.bool) {
        var printer = try Printer.init(allocator, &tree, encoding, &trace_nodes);
        defer printer.deinit();
        try printer.printRoot(height, depth);
    }

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
    try parseKey(&key_buffer);

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

    const height = parseHeight();
    const depth = parseDepth();

    var trace_nodes = okra.NodeList.init(allocator);
    const trace = if (trace_option.value.bool) &trace_nodes else null;

    var dbi = std.ArrayList(u8).init(allocator);
    defer dbi.deinit();
    const name = try parseName(&dbi);

    const log = if (verbose_option.value.bool) std.io.getStdOut().writer() else null;

    const path = try lmdb.utils.resolvePath(std.fs.cwd(), args[0]);
    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
    errdefer txn.abort();

    const db = try lmdb.Database.open(txn, .{ .name = name });
    var tree = try okra.Tree.open(allocator, db, .{ .log = log, .trace = trace });
    defer tree.close();

    try tree.delete(key_buffer.items);

    if (trace_option.value.bool) {
        var printer = try Printer.init(allocator, &tree, encoding, &trace_nodes);
        defer printer.deinit();

        var stdin = std.io.getStdIn().writer();
        _ = try stdin.write(&.{12});

        try printer.printRoot(height, depth);
    }

    try txn.commit();
}

fn init(args: []const []const u8) !void {
    if (args.len > 1) {
        fail("too many arguments", .{});
    } else if (args.len == 0) {
        fail("path argument required", .{});
    }

    const iota = iota_option.value.int orelse unreachable;
    if (iota < 0) {
        fail("iota must be a non-negative integer", .{});
    }

    var key: [4]u8 = undefined;
    var value = [4]u8{ 0xff, 0xff, 0xff, 0xff };

    std.fs.cwd().access(args[0], .{ .mode = .read_write }) catch |err| {
        switch (err) {
            error.FileNotFound => try std.fs.cwd().makeDir(args[0]),
            else => {},
        }
    };

    const path = try lmdb.utils.resolvePath(std.fs.cwd(), args[0]);
    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadWrite });
    errdefer txn.abort();

    const db = try lmdb.Database.open(txn, .{});
    var builder = try okra.Builder.open(allocator, db, .{});
    defer builder.deinit();

    var i: u32 = 0;
    while (i < iota) : (i += 1) {
        std.mem.writeIntBig(u32, &key, i);
        try builder.set(&key, &value);
    }

    try builder.build();
    try txn.commit();
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

fn parseEncoding() utils.Encoding {
    const encoding = encoding_option.value.string orelse unreachable;
    if (std.mem.eql(u8, encoding, "utf-8")) {
        return utils.Encoding.utf8;
    } else if (std.mem.eql(u8, encoding, "hex")) {
        return utils.Encoding.hex;
    } else {
        fail("invalid encoding", .{});
    }
}

fn parseKey(key_buffer: *std.ArrayList(u8)) !void {
    const encoding = parseEncoding();

    if (key_option.value.string) |key| {
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
}

fn parseName(dbi: *std.ArrayList(u8)) !?[*:0]u8 {
    if (name_option.value.string) |name| {
        try dbi.resize(name.len + 1);
        std.mem.copy(u8, dbi.items[0..name.len], name);
        dbi.items[name.len] = 0;
        return dbi.items[0..name.len :0];
    } else {
        return null;
    }
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    var w = std.io.getStdErr().writer();
    std.fmt.format(w, "ERROR: ", .{}) catch unreachable;
    std.fmt.format(w, fmt, args) catch unreachable;
    std.fmt.format(w, "\n", .{}) catch unreachable;
    std.os.exit(1);
}

pub fn main() !void {
    return cli.run(app, allocator);
}
