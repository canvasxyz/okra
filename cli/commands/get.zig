const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const allocator = std.heap.c_allocator;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("../utils.zig");

pub const command = &cli.Command{
    .name = "get",
    .help = "Get a value by key",
    .action = run,
    .options = &.{
        &name_option,
        &key_option,
        &key_encoding_option,
        &value_encoding_option,
    },
};

var config = struct {
    name: []const u8 = "",
    key: []const u8 = "",
    key_encoding: utils.Encoding = .hex,
    value_encoding: utils.Encoding = .hex,
}{};

var name_option = cli.Option{
    .long_name = "name",
    .short_alias = 'n',
    .help = "Select a named database",
    .value_ref = cli.mkRef(&config.name),
};

var key_option = cli.Option{
    .long_name = "key",
    .short_alias = 'k',
    .help = "Entry key",
    .value_ref = cli.mkRef(&config.key),
    .required = true,
};

var key_encoding_option = cli.Option{
    .long_name = "key-encoding",
    .short_alias = 'K',
    .help = "\"raw\" or \"hex\" (default \"hex\")",
    .value_ref = cli.mkRef(&config.key_encoding),
};

var value_encoding_option = cli.Option{
    .long_name = "value-encoding",
    .short_alias = 'V',
    .help = "\"raw\" or \"hex\" (default \"hex\")",
    .value_ref = cli.mkRef(&config.value_encoding),
};

fn run(args: []const []const u8) !void {
    if (args.len > 1) {
        utils.fail("too many arguments", .{});
    } else if (args.len == 0) {
        utils.fail("missing path argument", .{});
    }

    var key_buffer = std.ArrayList(u8).init(allocator);
    defer key_buffer.deinit();

    if (config.key.len == 0) {
        utils.fail("key cannot be empty", .{});
    }

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

    const env = try lmdb.Environment.open(args[0], .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
    defer txn.abort();

    const name = if (config.name.len > 0) config.name else null;
    const dbi = try txn.openDatabase(name, .{});

    var tree = try okra.Tree.open(allocator, txn, dbi, .{});
    defer tree.close();

    if (try tree.get(key_buffer.items)) |value| {
        const stdout = std.io.getStdOut().writer();
        switch (config.value_encoding) {
            .raw => {
                try stdout.print("{s}\n", .{value});
            },
            .hex => {
                try stdout.print("{s}\n", .{hex(value)});
            },
        }
    }
}
