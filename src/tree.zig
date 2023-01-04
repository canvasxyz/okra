const std = @import("std");

const lmdb = @import("lmdb");

const header = @import("header.zig");
const transaction = @import("transaction.zig");
const iterator = @import("iterator.zig");
const cursor = @import("cursor.zig");
const utils = @import("utils.zig");

pub fn Tree(comptime K: u8, comptime Q: u32) type {
    return struct {
        pub const Options = struct { map_size: usize = 10485760 };
        pub const Header = header.Header(K, Q);
        pub const Transaction = transaction.Transaction(K, Q);
        pub const Iterator = iterator.Iterator(K, Q);
        pub const Cursor = cursor.Cursor(K, Q);

        const Self = @This();

        allocator: std.mem.Allocator,
        env: lmdb.Environment,

        pub fn open(allocator: std.mem.Allocator, path: [:0]u8, options: Options) !*Self {
            const env = try lmdb.Environment.open(path, .{ .map_size = options.map_size });
            try Header.initialize(env);

            const self = try allocator.create(Self);
            self.allocator = allocator;
            self.env = env;
            return self;
        }

        pub fn close(self: *Self) void {
            self.env.close();
            self.allocator.destroy(self);
        }
    };
}

test "Tree.open()" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const tree = try Tree(32, 4).open(allocator, path, .{});
    defer tree.close();

    try lmdb.expectEqualEntries(tree.env, &.{
        .{ &[_]u8{0}, &utils.parseHash("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
    });
}
