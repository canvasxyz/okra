const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("../utils.zig");

var config = struct {
    path: []const u8 = "",
    name: []const u8 = "",
    level: i32 = -1,
    key: []const u8 = "",
    key_encoding: utils.Encoding = .hex,
}{};

var path_arg = cli.PositionalArg{
    .name = "path",
    .help = "path to data directory",
    .value_ref = cli.mkRef(&config.path),
};

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

pub const command = &cli.Command{
    .name = "ls",
    .description = .{ .one_line = "list the children of an internal node" },
    .target = .{ .action = .{ .exec = run, .positional_args = .{ .args = &.{&path_arg} } } },
    .options = &.{
        &name_option,
        &level_option,
        &key_option,
        &key_encoding_option,
    },
};

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var key_buffer = std.ArrayList(u8).init(gpa.allocator());
    defer key_buffer.deinit();

    if (config.key.len > 0) {
        switch (config.key_encoding) {
            .raw => {
                try key_buffer.resize(config.key.len);
                @memcpy(key_buffer.items, config.key);
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

    var dir = try std.fs.cwd().openDir(config.path, .{});
    defer dir.close();

    const env = try utils.open(dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadOnly });
    errdefer txn.abort();

    const db = try utils.openDB(gpa.allocator(), txn, config.name, .{});

    var tree = try okra.Tree.init(gpa.allocator(), db, .{});
    defer tree.deinit();

    const root = if (config.level == -1)
        try tree.getRoot()
    else
        try tree.getNode(@intCast(config.level), key_buffer.items) orelse
            utils.fail("node not found", .{});

    try stdout.print("level | {s: <32} | key\n", .{"hash"});
    try stdout.print("----- | {s:-<32} | {s:-<32}\n", .{ "", "" });
    try printNode(stdout, root);

    if (root.level > 0) {
        try stdout.print("----- | {s:-<32} | {s:-<32}\n", .{ "", "" });

        const range = okra.Iterator.Range{
            .level = root.level - 1,
            .lower_bound = .{ .key = root.key, .inclusive = true },
        };

        var iterator = try okra.Iterator.init(gpa.allocator(), db, range);
        defer iterator.deinit();

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
