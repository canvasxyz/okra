const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");

const Tree = @import("tree.zig").Tree;
const Header = @import("header.zig").Header;
const Transaction = @import("transaction.zig").Transaction;
const utils = @import("utils.zig");

pub fn Cursor(comptime K: u8, comptime Q: u32) type {
    return struct {
        allocator: std.mem.Allocator,
        cursor: lmdb.Cursor,
        key: std.ArrayList(u8),

        const Self = @This();

        pub const Node = struct { level: u8, key: ?[]const u8, hash: *const [K]u8 };

        pub fn open(allocator: std.mem.Allocator, txn: *const Transaction(K, Q)) !*Self {
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

fn h(comptime value: *const [32]u8) [16]u8 {
    var buffer: [16]u8 = undefined;
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
    const Node = Cursor(16, 4).Node;

    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const tree = try Tree(16, 4).open(allocator, path, .{});
    defer tree.close();

    const txn = try Transaction(16, 4).open(allocator, tree, .{ .read_only = false });
    defer txn.abort();

    try txn.set("a", "foo");
    try txn.set("b", "bar");
    try txn.set("c", "baz");

    // okay here we expect
    // L0 -----------------------------
    // af1349b9f5f9a1a6a0404dea36dcc949
    // 2f26b85f65eb9f7a8ac11e79e710148d "a"
    // 684f1047a178e6cf9fff759ba1edec2d "b"
    // 56cb13c78823525b08d471b6c1201360 "c"
    // L1 -----------------------------
    // 6c5483c477697c881f6b03dc23a52c7f
    // d139f1b3444bc84fd46cbd56f7fe2fb5 "a"
    // L2 -----------------------------
    // 2453a3811e50851b4fc0bb95e1415b07

    const cursor = try Cursor(16, 4).open(allocator, txn);
    defer cursor.close();

    const root = try cursor.goToRoot();
    try expectEqual(@as(u8, 2), root.level);
    try expectEqual(@as(?[]const u8, null), root.key);
    try expectEqualSlices(u8, &h("2453a3811e50851b4fc0bb95e1415b07"), root.hash);
    try expectEqual(@as(?Node, null), try cursor.goToNext());

    {
        const node = try cursor.goToNode(1, null);
        try expectEqual(@as(u8, 1), node.level);
        try expectEqual(@as(?[]const u8, null), node.key);
        try expectEqualSlices(u8, &h("6c5483c477697c881f6b03dc23a52c7f"), node.hash);
    }

    try if (try cursor.goToNext()) |node| {
        try expectEqual(@as(u8, 1), node.level);
        try expectEqualKeys("a", node.key);
        try expectEqualSlices(u8, &h("d139f1b3444bc84fd46cbd56f7fe2fb5"), node.hash);
    } else error.NotFound;

    try expectEqual(@as(?Node, null), try cursor.goToNext());

    try txn.set("x", "hello world"); // a4fefb21af5e42531ed2b7860cf6e80a
    try txn.set("z", "lorem ipsum"); // 4d41c77b6d7d709e7dd9803e07060681

    try if (try cursor.seek(0, "y")) |node| {
        try expectEqual(@as(u8, 0), node.level);
        try expectEqualKeys("z", node.key);
        try expectEqualSlices(u8, &h("4d41c77b6d7d709e7dd9803e07060681"), node.hash);
    } else error.NotFound;

    try if (try cursor.goToPrevious()) |node| {
        try expectEqual(@as(u8, 0), node.level);
        try expectEqualKeys("x", node.key);
        try expectEqualSlices(u8, &h("a4fefb21af5e42531ed2b7860cf6e80a"), node.hash);
    } else error.NotFound;

    try if (try cursor.seek(0, null)) |node| {
        try expectEqual(@as(u8, 0), node.level);
        try expectEqualKeys(null, node.key);
        try expectEqualSlices(u8, &h("af1349b9f5f9a1a6a0404dea36dcc949"), node.hash);
    } else error.NotFound;

    try expectEqual(@as(?Node, null), try cursor.goToPrevious());
}
