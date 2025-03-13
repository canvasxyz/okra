const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

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
        .name = "cat",
        .description = .{ .one_line = "print the key/value entries to stdout" },
        .target = .{ .action = .{ .exec = run, .positional_args = .{ .required = args.items } } },
        .options = options.items,
    };
}

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

    var tree = try okra.Tree.open(gpa.allocator(), db, .{});
    defer tree.deinit();

    const range = okra.Iterator.Range{
        .level = 0,
        .lower_bound = .{ .key = null, .inclusive = false },
    };

    var iterator = try okra.Iterator.init(gpa.allocator(), db, range);
    defer iterator.deinit();

    while (try iterator.next()) |node| {
        switch (config.key_encoding) {
            .raw => try stdout.print("{s}\t", .{node.key.?}),
            .hex => try stdout.print("{s}\t", .{hex(node.key.?)}),
        }

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
}
