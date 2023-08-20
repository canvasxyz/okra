const std = @import("std");

const lmdb = @import("lmdb");

pub fn Tree(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);

    return struct {
        const Self = @This();
        pub const Options = struct {
            create: bool = true,
            map_size: usize = 10485760,
            dbs: ?[]const [*:0]const u8 = null,
        };

        allocator: std.mem.Allocator,
        is_open: bool = false,
        env: lmdb.Environment,

        pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !Self {
            var tree: Self = undefined;
            try tree.init(allocator, path, options);
            return tree;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void {
            std.fs.accessAbsoluteZ(path, .{ .mode = .read_write }) catch |err| {
                if (err == std.os.AccessError.FileNotFound and options.create) {
                    try std.fs.makeDirAbsoluteZ(path);
                } else {
                    return err;
                }
            };

            self.allocator = allocator;
            self.env = try lmdb.Environment.open(path, .{
                .map_size = options.map_size,
                .max_dbs = if (options.dbs) |dbs| @as(u32, @intCast(dbs.len)) else 0,
            });

            self.is_open = true;

            errdefer self.close();

            if (options.dbs) |dbs| {
                for (dbs) |dbi| try Header.initialize(self.env, dbi);
            } else {
                try Header.initialize(self.env, null);
            }
        }

        pub fn close(self: *Self) void {
            if (self.is_open) {
                self.is_open = false;
                self.env.close();
            }
        }
    };
}
