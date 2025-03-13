const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

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
        .long_name = "depth",
        .short_alias = 'd',
        .help = "tree depth",
        .value_ref = r.mkRef(&config.depth),
    });

    try options.append(.{
        .long_name = "height",
        .short_alias = 'h',
        .help = "align to fixed height",
        .value_ref = r.mkRef(&config.height),
    });

    // try options.append(.{
    //     .long_name = "key",
    //     .short_alias = 'k',
    //     .help = "node key",
    //     .value_ref = r.mkRef(&config.key),
    // });

    // try options.append(.{
    //     .long_name = "key-encoding",
    //     .short_alias = 'K',
    //     .help = "\"raw\" or \"hex\" (default \"hex\")",
    //     .value_ref = r.mkRef(&config.key_encoding),
    // });

    return cli.Command{
        .name = "tree",
        .description = .{ .one_line = "print the tree structure" },
        .target = .{ .action = .{ .exec = run, .positional_args = .{ .required = args.items } } },
        .options = options.items,
    };
}

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

    var tree = try okra.Tree.open(gpa.allocator(), db, .{});
    defer tree.deinit();

    var printer = try Printer.init(gpa.allocator(), &tree, config.key_encoding);

    defer printer.deinit();

    try printer.printRoot(
        if (config.height == -1) null else @intCast(config.height),
        if (config.depth == -1) null else @intCast(config.depth),
    );
}
