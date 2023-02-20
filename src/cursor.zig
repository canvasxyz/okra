const std = @import("std");
const expectEqual = std.testing.expectEqual;

const lmdb = @import("lmdb");

pub fn Cursor(comptime K: u8, comptime Q: u32) type {
    const Node = @import("node.zig").Node(K, Q);
    const Transaction = @import("transaction.zig").Transaction(K, Q);
    const SkipListCursor = @import("skip_list_cursor.zig").SkipListCursor(K, Q);

    return struct {
        allocator: std.mem.Allocator,
        is_open: bool = false,
        skip_list_cursor: SkipListCursor,

        const Self = @This();

        pub fn open(allocator: std.mem.Allocator, txn: *const Transaction) !Self {
            var cursor: Self = undefined;
            try cursor.init(allocator, txn);
            return cursor;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, txn: *const Transaction) !void {
            try self.skip_list_cursor.init(allocator, txn.txn);
            self.is_open = true;
            self.allocator = allocator;
        }

        pub fn close(self: *Self) void {
            if (self.is_open) {
                self.is_open = false;
                self.skip_list_cursor.close();
            }
        }

        pub fn goToRoot(self: *Self) !Node {
            return try self.skip_list_cursor.goToRoot();
        }

        pub fn goToFirst(self: *Self, level: u8) !Node {
            return try self.skip_list_cursor.goToFirst(level);
        }

        pub fn goToLast(self: *Self, level: u8) !Node {
            return try self.skip_list_cursor.goToLast(level);
        }

        pub fn goToNode(self: *Self, level: u8, key: ?[]const u8) !Node {
            return try self.skip_list_cursor.goToNode(level, key);
        }

        pub fn goToNext(self: *Self, level: u8) !?Node {
            return try self.skip_list_cursor.goToNext(level);
        }

        pub fn goToPrevious(self: *Self, level: u8) !?Node {
            return try self.skip_list_cursor.goToPrevious(level);
        }

        pub fn seek(self: *Self, level: u8, key: ?[]const u8) !?Node {
            return try self.skip_list_cursor.seek(level, key);
        }

        pub fn getCurrentNode(self: Self) !Node {
            return try self.skip_list_cursor.getCurrentNode();
        }
    };
}
