const std = @import("std");

const lmdb = @import("lmdb");

pub fn Iterator(
    comptime Transaction: type,
    comptime getTransaction: fn (txn: *const Transaction) lmdb.Transaction,
    comptime Entry: type,
    comptime Error: type,
    comptime getEntry: fn (key: []const u8, value: []const u8) Error!Entry,
) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        cursor: lmdb.Cursor,
        key: std.ArrayList(u8),

        pub fn open(allocator: std.mem.Allocator, txn: *const Transaction) !*Self {
            const self = try allocator.create(Self);
            self.allocator = allocator;
            self.key = std.ArrayList(u8).init(allocator);
            self.cursor = try lmdb.Cursor.open(getTransaction(txn));
            try self.setKey(0, &[_]u8{});
            try self.cursor.goToKey(self.key.items);
            return self;
        }

        // pub fn open(allocator: std.mem.Allocator, txn: *const Transaction) !Self {
        //     var iterator: Self = undefined;
        //     try iterator.init(allocator, txn);
        //     return iterator;
        // }

        // pub fn init(self: *Self, allocator: std.mem.Allocator, txn: *const Transaction) !void {
        //     self.cursor = try lmdb.Cursor.open(getTransaction(txn));
        //     self.key = std.ArrayList(u8).init(allocator);
        //     try self.setKey(0, &[_]u8{});
        //     try self.cursor.goToKey(self.key.items);
        // }

        pub fn close(self: *Self) void {
            self.key.deinit();
            self.cursor.close();
            self.allocator.destroy(self);
        }

        pub fn seek(self: *Self, key: []const u8) !?Entry {
            try self.setKey(0, key);
            if (try self.cursor.seek(self.key.items)) |k| {
                if (k.len > 0 and k[0] == 0) {
                    const value = try self.cursor.getCurrentValue();
                    return try getEntry(k[1..], value);
                }
            }

            return null;
        }

        pub fn next(self: *Self) !?Entry {
            if (try self.cursor.goToNext()) |k| {
                if (k.len > 0 and k[0] == 0) {
                    const value = try self.cursor.getCurrentValue();
                    return try getEntry(k[1..], value);
                }
            }

            return null;
        }

        pub fn previous(self: *Self) !?Entry {
            if (try self.cursor.goToPrevious()) |k| {
                if (k.len > 0 and k[0] == 0) {
                    const value = try self.cursor.getCurrentValue();
                    return try getEntry(k[1..], value);
                }
            }

            return null;
        }

        fn setKey(self: *Self, level: u8, key: []const u8) !void {
            try self.key.resize(1 + key.len);
            self.key.items[0] = level;
            std.mem.copy(u8, self.key.items[1..], key);
        }
    };
}
