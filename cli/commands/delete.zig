const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const allocator = std.heap.c_allocator;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("../utils.zig");

var config = struct {
    path: []const u8 = "",
    name: []const u8 = "",
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

pub const command = &cli.Command{
    .name = "delete",
    .description = .{ .one_line = "delete a value by key" },
    .target = .{ .action = .{ .exec = run, .positional_args = .{ .args = &.{&path_arg} } } },
    .options = &.{
        &name_option,
        &key_option,
        &key_encoding_option,
    },
};

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var key_buffer = std.ArrayList(u8).init(allocator);
    defer key_buffer.deinit();

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

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    errdefer txn.abort();

    const db = try utils.openDB(gpa.allocator(), txn, config.name, .{});

    {
        var map = try okra.Map.init(allocator, db, .{});
        defer map.deinit();

        try map.delete(key_buffer.items);
    }

    try txn.commit();
}
