const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("lmdb");

const Tree = @import("tree.zig").Tree;
const Header = @import("header.zig").Header;
const Transaction = @import("transaction.zig").Transaction;
const utils = @import("utils.zig");

pub fn Iterator(comptime Q: u8, comptime K: u8) type {
    return struct {
        allocator: std.mem.Allocator,
        cursor: lmdb.Cursor,
        key_buffer: std.ArrayList(u8),

        const Self = @This();

        pub const Entry = struct { key: []const u8, value: []const u8 };

        pub fn open(allocator: std.mem.Allocator, txn: *const Transaction(Q, K)) !*Self {
            const self = try allocator.create(Self);
            self.allocator = allocator;
            self.key_buffer = std.ArrayList(u8).init(allocator);
            self.cursor = try lmdb.Cursor.open(txn.txn);
            try self.setKey(0, &[_]u8{});
            try self.cursor.goToKey(self.key_buffer.items);
            return self;
        }

        pub fn close(self: *Self) void {
            self.cursor.close();
            self.key_buffer.deinit();
            self.allocator.destroy(self);
        }

        pub fn goToFirst(self: *Self) !?Entry {
            try self.cursor.goToKey(&[_]u8{0});
            return try self.goToNext();
        }

        pub fn goToLast(self: *Self) !?Entry {
            if (try self.cursor.seek(&[_]u8{1})) |_| {
                return try self.goToPrevious();
            }

            return null;
        }

        pub fn seek(self: *Self, key: []const u8) !?Entry {
            // we have to handle the case of ken.len == 0.
            // the iterator abstraction doesn't have null nodes,
            // so the expected behavior is to seek to the very first entry.
            if (key.len == 0) {
                try self.cursor.goToKey(&[_]u8{0});
                return try self.goToNext();
            }

            try self.setKey(0, key);
            if (try self.cursor.seek(self.key_buffer.items)) |k| {
                if (k.len > 1 and k[0] == 0) {
                    return try self.getEntry();
                }
            }

            return null;
        }

        pub fn goToNext(self: *Self) !?Entry {
            if (try self.cursor.goToNext()) |key| {
                if (key.len > 1 and key[0] == 0) {
                    return try self.getEntry();
                }
            }

            return null;
        }

        pub fn goToPrevious(self: *Self) !?Entry {
            if (try self.cursor.goToPrevious()) |key| {
                if (key.len > 1 and key[0] == 0) {
                    return try self.getEntry();
                }
            }

            return null;
        }

        fn setKey(self: *Self, level: u8, key: []const u8) !void {
            try self.key_buffer.resize(1 + key.len);
            self.key_buffer.items[0] = level;
            std.mem.copy(u8, self.key_buffer.items[1..], key);
        }

        fn getEntry(self: *Self) !Entry {
            const key = try self.cursor.getCurrentKey();
            if (key.len < 2 or key[0] != 0) {
                return error.InvalidDatabase;
            }

            const value = try self.cursor.getCurrentValue();
            if (value.len < K) {
                return error.InvalidDatabase;
            }

            return Entry{ .key = key[1..], .value = value[K..] };
        }
    };
}

test "Iterator.open()" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const tree = try Tree(4, 32).open(allocator, path, .{});
    defer tree.close();

    const txn = try Transaction(4, 32).open(allocator, tree, .{ .read_only = true });
    defer txn.abort();

    const iter = try Iterator(4, 32).open(allocator, txn);
    defer iter.close();

    try expectEqual(try iter.goToFirst(), null);
    try expectEqual(try iter.goToLast(), null);
}

test "Iterator(a, b, c)" {
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

    const iter = try Iterator(4, 32).open(allocator, txn);
    defer iter.close();

    try if (try iter.goToFirst()) |entry| {
        try expectEqualSlices(u8, entry.key, "a");
        try expectEqualSlices(u8, entry.value, "foo");
    } else error.NotFound;

    try if (try iter.goToLast()) |entry| {
        try expectEqualSlices(u8, entry.key, "c");
        try expectEqualSlices(u8, entry.value, "baz");
    } else error.NotFound;

    try if (try iter.goToPrevious()) |entry| {
        try expectEqualSlices(u8, entry.key, "b");
        try expectEqualSlices(u8, entry.value, "bar");
    } else error.NotFound;
}

test "Iterator: iota(10)" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const tree = try Tree(4, 32).open(allocator, path, .{});
    defer tree.close();

    const txn = try Transaction(4, 32).open(allocator, tree, .{ .read_only = false });
    defer txn.abort();

    var value: [32]u8 = undefined;
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        Sha256.hash(&[_]u8{i}, &value, .{});
        try txn.set(&[_]u8{i}, &value);
    }

    try txn.delete(&[_]u8{3});

    const iter = try Iterator(4, 32).open(allocator, txn);
    defer iter.close();

    try if (try iter.seek(&[_]u8{3})) |entry| {
        try expectEqualSlices(u8, entry.key, &[_]u8{4});
    } else error.NotFound;

    try if (try iter.seek(&[_]u8{})) |entry| {
        try expectEqualSlices(u8, entry.key, &[_]u8{0});
    } else error.NotFound;

    try if (try iter.goToNext()) |entry| {
        try expectEqualSlices(u8, entry.key, &[_]u8{1});
    } else error.NotFound;

    try if (try iter.seek(&[_]u8{9})) |entry| {
        try expectEqualSlices(u8, entry.key, &[_]u8{9});
    } else error.NotFound;

    try expectEqual(try iter.goToNext(), null);
}
