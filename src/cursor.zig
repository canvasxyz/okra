const std = @import("std");
const expectEqual = std.testing.expectEqual;

const lmdb = @import("lmdb");

pub fn Cursor(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);
    const Node = @import("node.zig").Node(K, Q);
    const NodeEncoder = @import("node_encoder.zig").NodeEncoder(K, Q);

    return struct {
        is_open: bool = false,
        level: u8 = 0xFF,
        cursor: lmdb.Cursor,
        encoder: NodeEncoder,

        const Self = @This();

        pub fn open(allocator: std.mem.Allocator, txn: lmdb.Transaction) !Self {
            var self: Self = undefined;
            try self.init(allocator, txn);
            return self;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, txn: lmdb.Transaction) !void {
            const cursor = try lmdb.Cursor.open(txn);
            self.is_open = true;
            self.level = 0xFF;
            self.cursor = cursor;
            self.encoder = NodeEncoder.init(allocator);
        }

        pub fn close(self: *Self) void {
            if (self.is_open) {
                self.is_open = false;
                self.encoder.deinit();
                self.cursor.close();
            }
        }

        pub fn goToRoot(self: *Self) !Node {
            if (try self.cursor.seek(&.{Header.MAXIMUM_HEIGHT})) |_| {
                if (try self.cursor.goToPrevious()) |k| {
                    if (k.len == 1) {
                        self.level = k[0];
                        return try self.getCurrentNode();
                    }
                }
            }

            return error.InvalidDatabase;
        }

        pub fn goToNode(self: *Self, level: u8, key: ?[]const u8) !Node {
            errdefer self.level = 0xFF;
            self.level = level;

            const k = try self.encoder.encodeKey(level, key);
            try self.cursor.goToKey(k);
            return try self.getCurrentNode();
        }

        pub fn goToNext(self: *Self) !?Node {
            if (self.level == 0xFF) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToNext()) |k| {
                if (k.len == 0) {
                    return error.InvalidDatabase;
                } else if (k[0] == self.level) {
                    return try self.getCurrentNode();
                } else {
                    self.level = 0xFF;
                }
            }

            return null;
        }

        pub fn goToPrevious(self: *Self) !?Node {
            if (self.level == 0xFF) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToPrevious()) |k| {
                if (k.len == 0) {
                    return error.InvalidDatabase;
                } else if (k[0] == self.level) {
                    return try self.getCurrentNode();
                } else {
                    self.level = 0xFF;
                }
            }

            return null;
        }

        pub fn seek(self: *Self, level: u8, key: ?[]const u8) !?Node {
            const entry_key = try self.encoder.encodeKey(level, key);
            if (try self.cursor.seek(entry_key)) |k| {
                if (k.len == 0) {
                    return error.InvalidDatabase;
                } else if (k[0] == level) {
                    self.level = level;
                    return try self.getCurrentNode();
                } else {
                    self.level = 0xFF;
                }
            }

            return null;
        }

        pub fn getCurrentNode(self: Self) !Node {
            const entry = try self.cursor.getCurrentEntry();
            return try Node.parse(entry.key, entry.value);
        }

        pub fn setCurrentNode(self: Self, hash: *const [K]u8, value: ?[]const u8) !void {
            try self.copyValue(hash, value);
            try self.cursor.setCurrentValue(self.buffer.items);
        }

        pub fn deleteCurrentNode(self: *Self) !void {
            try self.cursor.deleteCurrentKey();
        }

        inline fn copyKey(self: *Self, level: u8, key: ?[]const u8) !void {
            if (key) |bytes| {
                try self.buffer.resize(1 + bytes.len);
                self.buffer.items[0] = level;
                std.mem.copy(u8, self.buffer.items[1..], bytes);
            } else {
                try self.buffer.resize(1);
                self.buffer.items[0] = level;
            }
        }

        inline fn copyValue(self: *Self, hash: *const [K]u8, value: ?[]const u8) !void {
            if (value) |bytes| {
                try self.buffer.resize(K + bytes.len);
                std.mem.copy(u8, self.buffer.items[0..K], hash);
                std.mem.copy(u8, self.buffer.items[K..], bytes);
            } else {
                try self.buffer.resize(K);
                std.mem.copy(u8, self.buffer.items, hash);
            }
        }
    };
}
