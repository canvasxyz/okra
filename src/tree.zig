const std = @import("std");

const lmdb = @import("lmdb");

pub fn Tree(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);

    return struct {
        const Self = @This();
        pub const Options = struct { map_size: usize = 10485760, dbs: ?[]const [*:0]const u8 = null };

        allocator: std.mem.Allocator,
        dbs: std.BufSet,
        env: lmdb.Environment,

        pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !Self {
            var tree: Self = undefined;
            try tree.init(allocator, path, options);
            return tree;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void {
            self.allocator = allocator;
            self.dbs = std.BufSet.init(allocator);
            self.env = try lmdb.Environment.open(path, .{
                .map_size = options.map_size,
                .max_dbs = if (options.dbs) |dbs| @intCast(u32, dbs.len) else 0,
            });

            errdefer self.close();

            if (options.dbs) |dbs| {
                if (dbs.len == 0) {
                    try Header.initialize(self.env, null);
                } else {
                    for (dbs) |dbi| {
                        try Header.initialize(self.env, dbi);
                        try self.dbs.insert(std.mem.span(dbi));
                    }
                }
            } else {
                try Header.initialize(self.env, null);
            }
        }

        pub fn close(self: *Self) void {
            self.dbs.deinit();
            self.env.close();
        }
    };
}
