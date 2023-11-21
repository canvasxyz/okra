const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const allocator = std.heap.c_allocator;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("../utils.zig");

pub const command = &cli.Command{
    .name = "cat",
    .help = "Print the key/value entries to stdout",
    .description = "okra cat [path]",
    .action = run,
    .options = &.{
        &name_option,
        &key_encoding_option,
        &value_encoding_option,
    },
};

var config = struct {
    name: []const u8 = "",
    key_encoding: utils.Encoding = .hex,
    value_encoding: utils.Encoding = .hex,
}{};

var name_option = cli.Option{
    .long_name = "name",
    .short_alias = 'n',
    .help = "Select a named database",
    .value_ref = cli.mkRef(&config.name),
};

var key_encoding_option = cli.Option{
    .long_name = "key-encoding",
    .short_alias = 'K',
    .help = "\"raw\" or \"hex\" (default \"raw\")",
    .value_ref = cli.mkRef(&config.key_encoding),
};

var value_encoding_option = cli.Option{
    .long_name = "value-encoding",
    .short_alias = 'V',
    .help = "\"raw\" or \"hex\" (default \"raw\")",
    .value_ref = cli.mkRef(&config.value_encoding),
};

fn run(args: []const []const u8) !void {
    if (args.len > 1) {
        utils.fail("too many arguments", .{});
    } else if (args.len == 0) {
        utils.fail("missing path argument", .{});
    }

    const stdout = std.io.getStdOut().writer();

    var dir = try std.fs.cwd().openDir(args[0], .{});
    defer dir.close();

    const env = try lmdb.Environment.open(dir, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
    defer txn.abort();

    const name = if (config.name.len > 0) config.name else null;
    const dbi = try txn.openDatabase(name, .{});

    const range = okra.Iterator.Range{
        .level = 0,
        .lower_bound = .{ .key = null, .inclusive = false },
    };

    var iterator = try okra.Iterator.open(allocator, txn, dbi, range);
    defer iterator.close();

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
