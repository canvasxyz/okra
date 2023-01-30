const std = @import("std");
const expectEqual = std.testing.expectEqual;

const lmdb = @import("lmdb");

pub fn Cursor(comptime K: u8, comptime Q: u32) type {
    const Transaction = @import("transaction.zig").Transaction(K, Q);
    const Header = @import("header.zig").Header(K, Q);
    const Node = @import("node.zig").Node(K, Q);

    return struct {
        allocator: std.mem.Allocator,
        cursor: lmdb.Cursor,
        key: std.ArrayList(u8),

        const Self = @This();

        pub fn open(allocator: std.mem.Allocator, txn: *const Transaction) !Self {
            var cursor: Self = undefined;
            try cursor.init(allocator, txn);
            return cursor;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, txn: *const Transaction) !void {
            const cursor = try lmdb.Cursor.open(txn.txn);
            self.allocator = allocator;
            self.cursor = cursor;
            self.key = std.ArrayList(u8).init(allocator);
        }

        pub fn close(self: *Self) void {
            self.key.deinit();
            self.cursor.close();
        }

        pub fn goToRoot(self: *Self) !Node {
            try self.cursor.goToKey(&Header.HEADER_KEY);
            if (try self.cursor.goToPrevious()) |k| {
                if (k.len == 1) {
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

        pub fn getCurrentNode(self: Self) !Node {
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
                .value = if (key.len > 1 and key[0] == 0) value[K..] else null,
            };
        }

        pub fn isCurrentNodeSplit(self: Self) !bool {
            const limit: comptime_int = (1 << 32) / @intCast(u33, Q);
            const node = try self.getCurrentNode();
            return node.key != null and std.mem.readIntBig(u32, node.hash[0..4]) < limit;
        }
    };
}
