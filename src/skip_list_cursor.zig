const std = @import("std");
const expectEqual = std.testing.expectEqual;

const lmdb = @import("lmdb");

pub fn SkipListCursor(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);
    const Node = @import("node.zig").Node(K, Q);

    return struct {
        is_open: bool = false,
        cursor: lmdb.Cursor,
        buffer: std.ArrayList(u8),

        const Self = @This();

        pub fn init(self: *Self, allocator: std.mem.Allocator, txn: lmdb.Transaction) !void {
            const cursor = try lmdb.Cursor.open(txn);

            self.is_open = true;
            self.cursor = cursor;
            self.buffer = std.ArrayList(u8).init(allocator);
        }

        pub fn close(self: *Self) void {
            if (self.is_open) {
                self.is_open = false;
                self.buffer.deinit();
                self.cursor.close();
            }
        }

        pub fn goToRoot(self: *Self) !Node {
            try self.cursor.goToKey(&Header.HEADER_KEY);
            if (try self.cursor.goToPrevious()) |k| {
                if (k.len == 1) {
                    return try self.getCurrentNode();
                }
            }

            return error.InvalidDatabase;
        }

        pub fn goToFirst(self: *Self, level: u8) !Node {
            return try self.goToNode(level, null);
        }

        pub fn goToLast(self: *Self, level: u8) !Node {
            try self.cursor.goToKey(&[_]u8{level + 1});
            if (try self.cursor.goToPrevious()) |previous_key| {
                if (previous_key[0] == level) {
                    return try self.getCurrentNode();
                }
            }

            return error.KeyNotFound;
        }

        pub fn goToNode(self: *Self, level: u8, key: ?[]const u8) !Node {
            try self.copyKey(level, key);
            try self.cursor.goToKey(self.buffer.items);
            return try self.getCurrentNode();
        }

        pub fn goToNext(self: *Self, level: u8) !?Node {
            if (try self.cursor.goToNext()) |k| {
                if (k.len == 0) {
                    return error.InvalidDatabase;
                } else if (k[0] == level) {
                    return try self.getCurrentNode();
                }
            }

            return null;
        }

        pub fn goToPrevious(self: *Self, level: u8) !?Node {
            if (try self.cursor.goToPrevious()) |k| {
                if (k.len == 0) {
                    return error.InvalidDatabase;
                } else if (k[0] == level) {
                    return try self.getCurrentNode();
                }
            }

            return null;
        }

        pub fn seek(self: *Self, level: u8, key: ?[]const u8) !?Node {
            try self.copyKey(level, key);
            if (try self.cursor.seek(self.buffer.items)) |k| {
                if (k.len == 0) {
                    return error.InvalidDatabase;
                } else if (k[0] == level) {
                    return try self.getCurrentNode();
                }
            }

            return null;
        }

        fn copyKey(self: *Self, level: u8, key: ?[]const u8) !void {
            if (key) |bytes| {
                try self.buffer.resize(1 + bytes.len);
                self.buffer.items[0] = level;
                std.mem.copy(u8, self.buffer.items[1..], bytes);
            } else {
                try self.buffer.resize(1);
                self.buffer.items[0] = level;
            }
        }

        pub fn getCurrentNode(self: Self) !Node {
            const entry = try self.cursor.getCurrentEntry();
            return try Node.parse(entry.key, entry.value);
        }

        pub fn setCurrentNode(self: *Self, hash: *const [K]u8, value: ?[]const u8) !void {
            const key = try self.cursor.getCurrentKey();
            if (key.len == 0) {
                return error.InvalidDatabase;
            }

            if (value) |bytes| {
                if (key[0] > 0 or key.len == 1) {
                    return error.InvalidValue;
                }

                try self.buffer.resize(K + bytes.len);
                std.mem.copy(u8, self.buffer.items[0..K], hash);
                std.mem.copy(u8, self.buffer.items[K..], bytes);

                try self.cursor.setCurrentValue(self.buffer.items);
            } else {
                if (key[0] == 0 and key.len > 1) {
                    return error.InvalidValue;
                }

                try self.cursor.setCurrentValue(hash);
            }
        }

        pub fn deleteCurrentNode(self: *Self) !void {
            try self.cursor.deleteCurrentKey();
        }
    };
}
