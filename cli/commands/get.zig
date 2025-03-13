const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("../utils.zig");

var config = struct {
    path: []const u8 = "",
    name: []const u8 = "",
    key: []const u8 = "",
    key_encoding: utils.Encoding = .hex,
    value_encoding: utils.Encoding = .hex,
}{};

pub fn command(r: *cli.AppRunner) !cli.Command {
    const allocator = r.arena.allocator();

    var args = std.ArrayList(cli.PositionalArg).init(allocator);
    try args.append(.{
        .name = "path",
        .help = "path to data directory",
        .value_ref = r.mkRef(&config.path),
    });

    var options = std.ArrayList(cli.Option).init(allocator);
    try options.append(.{
        .long_name = "name",
        .short_alias = 'n',
        .help = "select a named database",
        .value_ref = r.mkRef(&config.name),
    });

    try options.append(.{
        .long_name = "key",
        .short_alias = 'k',
        .help = "Entry key",
        .value_ref = r.mkRef(&config.key),
        .required = true,
    });

    try options.append(.{
        .long_name = "key-encoding",
        .short_alias = 'K',
        .help = "\"raw\" or \"hex\" (default \"hex\")",
        .value_ref = r.mkRef(&config.key_encoding),
    });

    try options.append(.{
        .long_name = "value-encoding",
        .short_alias = 'V',
        .help = "\"raw\" or \"hex\" (default \"hex\")",
        .value_ref = r.mkRef(&config.value_encoding),
    });

    return cli.Command{
        .name = "get",
        .description = .{ .one_line = "get a value by key" },
        .target = .{ .action = .{ .exec = run, .positional_args = .{ .required = args.items } } },
        .options = options.items,
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var key_buffer = std.ArrayList(u8).init(gpa.allocator());
    defer key_buffer.deinit();

    if (config.key.len == 0) {
        utils.fail("key cannot be empty", .{});
    }

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

    var dir = try std.fs.cwd().openDir(config.path, .{});
    defer dir.close();

    const env = try utils.open(dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadOnly });
    errdefer txn.abort();

    const db = try utils.openDB(gpa.allocator(), txn, config.name, .{});

    var tree = try okra.Tree.open(gpa.allocator(), db, .{});
    defer tree.deinit();

    const node = try tree.getNode(0, key_buffer.items) orelse return;

    const stdout = std.io.getStdOut().writer();

    switch (tree.mode) {
        .Index => try stdout.print("{s}\n", .{hex(node.hash)}),
        .Store => {
            const value = node.value orelse @panic("internal error");
            switch (config.value_encoding) {
                .raw => try stdout.print("{s}\n", .{value}),
                .hex => try stdout.print("{s}\n", .{hex(value)}),
            }
        },
    }
}
