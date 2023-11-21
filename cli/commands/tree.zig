const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const allocator = std.heap.c_allocator;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const Printer = @import("../printer.zig");
const utils = @import("../utils.zig");

pub const command = &cli.Command{
    .name = "tree",
    .help = "Print the tree structure",
    .action = run,
    .options = &.{
        &name_option,
        &depth_option,
        &height_option,
        // &key_option,
        &key_encoding_option,
    },
};

var config = struct {
    name: []const u8 = "",
    level: i32 = -1,
    depth: i32 = -1,
    height: i32 = -1,
    key_encoding: utils.Encoding = .hex,
}{};

var name_option = cli.Option{
    .long_name = "name",
    .short_alias = 'n',
    .help = "Select a named database",
    .value_ref = cli.mkRef(&config.name),
};

var depth_option = cli.Option{
    .long_name = "depth",
    .short_alias = 'd',
    .help = "tree depth",
    .value_ref = cli.mkRef(&config.depth),
};

var height_option = cli.Option{
    .long_name = "height",
    .short_alias = 'h',
    .help = "align to fixed height",
    .value_ref = cli.mkRef(&config.height),
};

// var key_option = cli.Option{
//     .long_name = "key",
//     .short_alias = 'k',
//     .help = "node key",
//     .value_ref = cli.mkRef(&config.key),
// };

var key_encoding_option = cli.Option{
    .long_name = "key-encoding",
    .short_alias = 'K',
    .help = "\"raw\" or \"hex\" (default \"raw\")",
    .value_ref = cli.mkRef(&config.key_encoding),
};

fn run(args: []const []const u8) !void {
    if (args.len > 1) {
        utils.fail("too many arguments", .{});
    } else if (args.len == 0) {
        utils.fail("path argument required", .{});
    }

    if (config.level < -1) {
        utils.fail("level must be -1 or a non-negative integer", .{});
    } else if (config.level >= 0xFF) {
        utils.fail("level must be less than 255", .{});
    }

    if (config.depth < -1) {
        utils.fail("depth must be -1 or a non-negative integer", .{});
    } else if (config.depth >= 0xFF) {
        utils.fail("depth must be less than 255", .{});
    }

    if (config.height < -1) {
        utils.fail("height must be -1 or a non-negative integer", .{});
    } else if (config.depth >= 0xFF) {
        utils.fail("height must be less than 255", .{});
    }

    const env = try lmdb.Environment.open(args[0], .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
    defer txn.abort();

    const name = if (config.name.len == 0) null else config.name;
    const dbi = try txn.openDatabase(name, .{});

    var tree = try okra.Tree.open(allocator, txn, dbi, .{});
    defer tree.close();

    var printer = try Printer.init(allocator, &tree, config.key_encoding, null);
    defer printer.deinit();

    try printer.printRoot(
        if (config.height == -1) null else @intCast(config.height),
        if (config.depth == -1) null else @intCast(config.depth),
    );
}
