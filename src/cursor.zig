const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");

const Tree = @import("tree.zig").Tree;
const Header = @import("header.zig").Header;
const Transaction = @import("transaction.zig").Transaction;
const utils = @import("utils.zig");

pub fn Cursor(comptime Q: u8, comptime K: u8) type {
    return struct {
        allocator: std.mem.Allocator,
        cursor: lmdb.Cursor,
        key: std.ArrayList(u8),

        const Self = @This();

        pub const Node = struct { level: u8, key: ?[]const u8, hash: *const [K]u8 };

        pub fn open(allocator: std.mem.Allocator, txn: *const Transaction(Q, K)) !*Self {
            const cursor = try lmdb.Cursor.open(txn.txn);
            const self = try allocator.create(Self);
            self.allocator = allocator;
            self.cursor = cursor;
            self.key = std.ArrayList(u8).init(allocator);
            return self;
        }

        pub fn close(self: *Self) void {
            self.key.deinit();
            self.cursor.close();
            self.allocator.destroy(self);
        }

        pub fn goToRoot(self: *Self) !Node {
            try self.cursor.goToKey(&[_]u8{0xFF});
            if (try self.cursor.goToPrevious()) |k| {
                if (k.len == 1 and k[0] > 0) {
                    // this is just to avoid Uninitialized errors later
                    try self.setKey(k[0], null);

                    return try self.getCurrentNode();
                }
            }

            return error.InvalidDatabase;
        }

        pub fn goToNode(self: *Self, level: u8, key: ?[]const u8) !Node {
            try self.setKey(level, key);
            try self.cursor.goToKey(self.key.items);
            return try self.getCurrentNode();
        }

        pub fn goToNext(self: *Self) !?Node {
            if (self.key.items.len == 0) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToNext()) |k| {
                if (k.len > 0 and k[0] == self.key.items[0]) {
                    return try self.getCurrentNode();
                }
            }

            return null;
        }

        pub fn goToPrevious(self: *Self) !?Node {
            if (self.key.items.len == 0) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToPrevious()) |k| {
                if (k.len > 0 and k[0] == self.key.items[0]) {
                    return try self.getCurrentNode();
                }
            }

            return null;
        }

        pub fn seek(self: *Self, level: u8, key: ?[]const u8) !?Node {
            try self.setKey(level, key);
            if (try self.cursor.seek(self.key.items)) |k| {
                if (k.len > 0 and k[0] == level) {
                    return try self.getCurrentNode();
                }
            }

            return null;
        }

        fn setKey(self: *Self, level: u8, key: ?[]const u8) !void {
            if (key) |bytes| {
                try self.key.resize(1 + bytes.len);
                self.key.items[0] = level;
                std.mem.copy(u8, self.key.items[1..], bytes);
            } else {
                try self.key.resize(1);
                self.key.items[0] = level;
            }
        }

        fn getCurrentNode(self: *Self) !Node {
            const key = try self.cursor.getCurrentKey();
            if (key.len == 0) {
                return error.InvalidDatabase;
            }

            const value = try self.cursor.getCurrentValue();
            if (value.len < K) {
                return error.InvalidDatabase;
            }

            return Node{
                .level = key[0],
                .key = if (key.len > 1) key[1..] else null,
                .hash = value[0..K],
            };
        }
    };
}

fn h(comptime value: *const [64]u8) [32]u8 {
    var buffer: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

fn expectEqualKeys(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected == null) {
        try expectEqual(expected, actual);
    } else {
        try expect(actual != null);
        try expectEqualSlices(u8, expected.?, actual.?);
    }
}

test "Cursor(a, b, c)" {
    const Node = Cursor(4, 32).Node;

    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const tree = try Tree(4, 32).open(allocator, path, .{});
    defer tree.close();

    const txn = try Transaction(4, 32).open(allocator, tree, .{ .read_only = false });
    defer txn.abort();

    try txn.set("a", "foo");
    try txn.set("b", "bar");
    try txn.set("c", "baz");

    const cursor = try Cursor(4, 32).open(allocator, txn);
    defer cursor.close();

    const root = try cursor.goToRoot();
    try expectEqual(@as(u8, 2), root.level);
    try expectEqual(@as(?[]const u8, null), root.key);
    try expectEqualSlices(u8, &h("3bb418b5746a2a7604f8ca73bb9270cd848c046ff3a3dcfdd0c53f063a8fd437"), root.hash);

    try expectEqual(@as(?Node, null), try cursor.goToNext());

    {
        const node = try cursor.goToNode(1, null);
        try expectEqual(@as(u8, 1), node.level);
        try expectEqual(@as(?[]const u8, null), node.key);
        try expectEqualSlices(u8, &h("67d7843048360902858aaad05aad36160453583837929d0d864983abccd46c13"), node.hash);
    }

    try if (try cursor.goToNext()) |node| {
        try expectEqual(@as(u8, 1), node.level);
        try expectEqualKeys("b", node.key);
        try expectEqualSlices(u8, &h("e902487cdf8c101eb5948eca70f3ba2bfa5ade4c68554b8d009c7e76de0b2a75"), node.hash);
    } else error.NotFound;

    try expectEqual(@as(?Node, null), try cursor.goToNext());

    // try expectEqualSlices(u8, root.level, "a");
    // try expectEqualSlices(u8, entry.value, "foo");

    // try if (try iter.first()) |entry| {
    //     try expectEqualSlices(u8, entry.key, "a");
    //     try expectEqualSlices(u8, entry.value, "foo");
    // } else error.NotFound;

    // try if (try iter.last()) |entry| {
    //     try expectEqualSlices(u8, entry.key, "c");
    //     try expectEqualSlices(u8, entry.value, "baz");
    // } else error.NotFound;

    // try if (try iter.previous()) |entry| {
    //     try expectEqualSlices(u8, entry.key, "b");
    //     try expectEqualSlices(u8, entry.value, "bar");
    // } else error.NotFound;
}
