const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("../utils.zig");

var config = struct {
    path: []const u8 = "",
    databases: usize = 0,
    name: []const u8 = "",
    iota: u32 = 0,
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
        .long_name = "databases",
        .help = "Maximum number of named databases",
        .value_ref = r.mkRef(&config.databases),
    });

    try options.append(.{
        .long_name = "name",
        .short_alias = 'n',
        .help = "Select a named database",
        .value_ref = r.mkRef(&config.name),
    });

    try options.append(.{
        .long_name = "iota",
        .help = "Initialize the tree with hashes of the first iota positive integers as sample data",
        .value_ref = r.mkRef(&config.iota),
    });

    return cli.Command{
        .name = "init",
        .description = .{ .one_line = "initialize an empty database environment" },
        .target = .{ .action = .{ .exec = run, .positional_args = .{ .required = args.items } } },
        .options = options.items,
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    try std.fs.cwd().makePath(config.path);

    var dir = try std.fs.cwd().openDir(config.path, .{});
    defer dir.close();

    const env = try utils.open(dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    errdefer txn.abort();

    const db = try utils.openDB(gpa.allocator(), txn, config.name, .{});

    var builder = try okra.Builder.init(gpa.allocator(), db, .{});
    defer builder.deinit();

    var key: [4]u8 = undefined;
    var value = [4]u8{ 0xff, 0xff, 0xff, 0xff };

    var i: u32 = 0;
    while (i < config.iota) : (i += 1) {
        std.mem.writeInt(u32, &key, i, .big);
        try builder.set(&key, &value);
    }

    try builder.build();
    try txn.commit();
}
