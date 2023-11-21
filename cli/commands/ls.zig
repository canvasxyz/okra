const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const allocator = std.heap.c_allocator;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("../utils.zig");

pub const command = &cli.Command{
    .name = "ls",
    .help = "list the children of an internal node",
    .description = "okra ls [path]",
    .action = run,
    .options = &.{
        &name_option,
        &level_option,
        &key_option,
        &key_encoding_option,
    },
};

var config = struct {
    name: []const u8 = "",
    level: i32 = -1,
    key: []const u8 = "",
    key_encoding: utils.Encoding = .hex,
}{};

var name_option = cli.Option{
    .long_name = "name",
    .short_alias = 'n',
    .help = "select a named database",
    .value_ref = cli.mkRef(&config.name),
};

var level_option = cli.Option{
    .long_name = "level",
    .short_alias = 'l',
    .help = "node level",
    .value_ref = cli.mkRef(&config.level),
};

var key_option = cli.Option{
    .long_name = "key",
    .short_alias = 'k',
    .help = "node key",
    .value_ref = cli.mkRef(&config.key),
};

var key_encoding_option = cli.Option{
    .long_name = "key-encoding",
    .short_alias = 'K',
    .help = "\"raw\" or \"hex\" (default \"hex\")",
    .value_ref = cli.mkRef(&config.key_encoding),
};

fn run(args: []const []const u8) !void {
    if (args.len > 1) {
        utils.fail("too many arguments", .{});
    } else if (args.len == 0) {
        utils.fail("missing path argument", .{});
    }

    var key_buffer = std.ArrayList(u8).init(allocator);
    defer key_buffer.deinit();

    if (config.key.len > 0) {
        switch (config.key_encoding) {
            .raw => {
                try key_buffer.resize(config.key.len);
                std.mem.copy(u8, key_buffer.items, config.key);
            },
            .hex => {
                if (config.key.len % 2 != 0) {
                    utils.fail("invalid hex input", .{});
                }

                try key_buffer.resize(config.key.len / 2);
                _ = try std.fmt.hexToBytes(key_buffer.items, config.key);
            },
        }
    }

    if (config.level == -1) {
        if (key_buffer.items.len != 0) {
            utils.fail("the root node's key is the empty string", .{});
        }
    } else if (config.level < 0) {
        utils.fail("level must be -1 or a non-negative integer", .{});
    } else if (config.level >= 0xFF) {
        utils.fail("level must be less than 254", .{});
    }

    const stdout = std.io.getStdOut().writer();

    const env = try lmdb.Environment.open(args[0], .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
    defer txn.abort();

    const name = if (config.name.len == 0) null else config.name;
    const dbi = try txn.openDatabase(name, .{});

    var tree = try okra.Tree.open(allocator, txn, dbi, .{});
    defer tree.close();

    const root = if (config.level == -1) try tree.getRoot() else try tree.getNode(@intCast(config.level), key_buffer.items) orelse utils.fail("node not found", .{});

    try stdout.print("level | {s: <32} | key\n", .{"hash"});
    try stdout.print("----- | {s:-<32} | {s:-<32}\n", .{ "", "" });
    try printNode(stdout, root);

    if (root.level > 0) {
        try stdout.print("----- | {s:-<32} | {s:-<32}\n", .{ "", "" });

        const range = okra.Iterator.Range{
            .level = root.level - 1,
            .lower_bound = .{ .key = root.key, .inclusive = true },
        };

        var iterator = try okra.Iterator.open(allocator, txn, dbi, range);
        defer iterator.close();

        var i: usize = 0;
        while (try iterator.next()) |node| : (i += 1) {
            if (i > 0 and node.isBoundary()) {
                break;
            } else {
                try printNode(stdout, node);
            }
        }
    }
}

fn getNode(tree: *okra.Tree, level: u8, key: ?[]const u8) !okra.Node {
    return try tree.getNode(level, key) orelse utils.fail("node not found", .{});
}

fn printNode(writer: std.fs.File.Writer, node: okra.Node) !void {
    if (node.key) |key|
        switch (config.key_encoding) {
            .raw => try writer.print("{d: >5} | {s} | {s}\n", .{ node.level, hex(node.hash), key }),
            .hex => try writer.print("{d: >5} | {s} | {s}\n", .{ node.level, hex(node.hash), hex(key) }),
        }
    else {
        try writer.print("{d: >5} | {s} |\n", .{ node.level, hex(node.hash) });
    }
}
