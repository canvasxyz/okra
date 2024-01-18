const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const allocator = std.heap.c_allocator;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const Printer = @import("../printer.zig");
const utils = @import("../utils.zig");

var config = struct {
    path: []const u8 = "",
    name: []const u8 = "",
    level: i32 = -1,
    depth: i32 = -1,
    height: i32 = -1,
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
    .help = "\"raw\" or \"hex\" (default \"hex\")",
    .value_ref = cli.mkRef(&config.key_encoding),
};

pub const command = &cli.Command{
    .name = "tree",
    .description = .{ .one_line = "print the tree structure" },
    .target = .{ .action = .{ .exec = run, .positional_args = .{ .args = &.{&path_arg} } } },
    .options = &.{
        &name_option,
        &depth_option,
        &height_option,
        // &key_option,
        &key_encoding_option,
    },
};

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

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

    var dir = try std.fs.cwd().openDir(config.path, .{});
    defer dir.close();

    const env = try utils.open(dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    errdefer txn.abort();

    const db = try utils.openDB(gpa.allocator(), txn, config.name, .{});

    var tree = try okra.Tree.init(allocator, db, .{});
    defer tree.deinit();

    var printer = try Printer.init(allocator, &tree, config.key_encoding);
    defer printer.deinit();

    try printer.printRoot(
        if (config.height == -1) null else @intCast(config.height),
        if (config.depth == -1) null else @intCast(config.depth),
    );
}
