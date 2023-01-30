const std = @import("std");

const lmdb = @import("lmdb");

pub fn Tree(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);

    return struct {
        const Self = @This();
        pub const Options = struct { map_size: usize = 10485760 };

        env: lmdb.Environment,
        allocator: std.mem.Allocator,

        pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !Self {
            var tree: Self = undefined;
            try tree.init(allocator, path, options);
            return tree;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void {
            const env = try lmdb.Environment.open(path, .{ .map_size = options.map_size });
            try Header.initialize(env);
            self.env = env;
            self.allocator = allocator;
        }

        pub fn close(self: *Self) void {
            self.env.close();
        }
    };
}
