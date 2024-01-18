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
    key_encoding: utils.Encoding = .hex,
    value_encoding: utils.Encoding = .hex,
}{};

var path_arg = cli.PositionalArg{
    .name = "path",
    .help = "path to data directory",
    .value_ref = cli.mkRef(&config.path),
};

pub const command = &cli.Command{
    .name = "cat",
    .description = .{ .one_line = "print the key/value entries to stdout" },
    .target = .{ .action = .{ .exec = run, .positional_args = .{ .args = &.{&path_arg} } } },
    .options = &.{
        &name_option,
        &key_encoding_option,
        &value_encoding_option,
    },
};

var name_option = cli.Option{
    .long_name = "name",
    .short_alias = 'n',
    .help = "select a named database",
    .value_ref = cli.mkRef(&config.name),
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

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    if (config.path.len == 0) {
        utils.fail("missing path argument", .{});
    }

    const stdout = std.io.getStdOut().writer();

    var dir = try std.fs.cwd().openDir(config.path, .{});
    defer dir.close();

    const env = try utils.open(dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadOnly });
    errdefer txn.abort();

    const db = try utils.openDB(gpa.allocator(), txn, config.name, .{});

    const range = okra.Iterator.Range{
        .level = 0,
        .lower_bound = .{ .key = null, .inclusive = false },
    };

    var iterator = try okra.Iterator.init(allocator, db, range);
    defer iterator.deinit();

    while (try iterator.next()) |node| {
        switch (config.key_encoding) {
            .raw => try stdout.print("{s}\t", .{node.key.?}),
            .hex => try stdout.print("{s}\t", .{hex(node.key.?)}),
        }

        switch (config.value_encoding) {
            .raw => try stdout.print("{s}\n", .{node.value.?}),
            .hex => try stdout.print("{s}\n", .{hex(node.value.?)}),
        }
    }
}
