const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const allocator = std.heap.c_allocator;

const cli = @import("zig-cli");
const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("../utils.zig");

pub const command = &cli.Command{
    .name = "init",
    .help = "initialize an empty database environment",
    .description = "okra init [path]",
    .action = run,
    .options = &.{
        &databases_option,
        &name_option,
        &iota_option,
    },
};

var config = struct {
    databases: usize = 0,
    name: []const u8 = "",
    iota: u32 = 0,
}{};

var databases_option = cli.Option{
    .long_name = "databases",
    .help = "Maximum number of named databases",
    .value_ref = cli.mkRef(&config.databases),
};

var name_option = cli.Option{
    .long_name = "name",
    .short_alias = 'n',
    .help = "Select a named database",
    .value_ref = cli.mkRef(&config.name),
};

var iota_option = cli.Option{
    .long_name = "iota",
    .help = "Initialize the tree with hashes of the first iota positive integers as sample data",
    .value_ref = cli.mkRef(&config.iota),
};

fn run(args: []const []const u8) !void {
    if (args.len > 1) {
        utils.fail("too many arguments", .{});
    } else if (args.len == 0) {
        utils.fail("path argument required", .{});
    }

    if (config.iota < 0) {
        utils.fail("iota must be a non-negative integer", .{});
    }

    var key: [4]u8 = undefined;
    var value = [4]u8{ 0xff, 0xff, 0xff, 0xff };

    std.fs.cwd().access(args[0], .{ .mode = .read_write }) catch |err| {
        switch (err) {
            error.FileNotFound => try std.fs.cwd().makeDir(args[0]),
            else => {
                return err;
            },
        }
    };

    try std.fs.cwd().makePath(args[0]);

    var dir = try std.fs.cwd().openDir(args[0], .{});
    defer dir.close();

    const env = try lmdb.Environment.open(dir, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadWrite });
    errdefer txn.abort();

    const name = if (config.name.len == 0) null else config.name;
    const dbi = try txn.openDatabase(name, .{});

    var builder = try okra.Builder.open(allocator, txn, dbi, .{});
    defer builder.deinit();

    var i: u32 = 0;
    while (i < config.iota) : (i += 1) {
        std.mem.writeIntBig(u32, &key, i);
        try builder.set(&key, &value);
    }

    try builder.build();
    try txn.commit();
}
