const std = @import("std");
const assert = std.debug.assert;

const lmdb = @import("lmdb");

const utils = @import("./utils.zig");

const INITIAL_KEY_CAPACITY = 32 + 2;

pub const SkipListCursor = struct {
    key: std.ArrayList(u8),
    txn: lmdb.Transaction,
    cursor: lmdb.Cursor,
    level: u16 = 0xFFFF,

    pub fn open(allocator: std.mem.Allocator, env: lmdb.Environment, read_only: bool) !SkipListCursor {
        const key = try std.ArrayList(u8).initCapacity(allocator, INITIAL_KEY_CAPACITY);
        errdefer key.deinit();
        const txn = try lmdb.Transaction.open(env, read_only);
        errdefer txn.abort();
        const cursor = try lmdb.Cursor.open(txn);
        return SkipListCursor { .key = key, .txn = txn, .cursor = cursor };
    }

    pub fn commit(self: *SkipListCursor) !void {
        self.key.deinit();
        try self.txn.commit();
    }

    pub fn abort(self: *SkipListCursor) void {
        self.key.deinit();
        self.txn.abort();
    }

    pub fn getCurrentKey(self: *SkipListCursor) ![]const u8 {
        const key = try self.cursor.getCurrentKey();
        return key[2..];
    }

    pub fn getCurrentValue(self: *SkipListCursor) ![]const u8 {
        return self.cursor.getCurrentValue();
    }

    fn setKey(self: *SkipListCursor, level: u16, key: []const u8) !void {
        try self.key.resize(2 + key.len);
        std.mem.writeIntBig(u16, self.key.items[0..2], level);
        std.mem.copy(u8, self.key.items[2..], key);
    }

    pub fn goToNode(self: *SkipListCursor, level: u16, key: []const u8) !void {
        self.level = level;
        try self.setKey(level, key);
        try self.cursor.goToKey(self.key.items);
    }

    pub fn goToNext(self: *SkipListCursor) !?[]const u8 {
        if (try self.cursor.goToNext()) |key| {
            if (utils.getLevel(key) == self.level) {
                return key[2..];
            }
        }

        return null;
    }

    pub fn goToPrevious(self: *SkipListCursor) !?[]const u8 {
        if (try self.cursor.goToPrevious()) |key| {
            if (utils.getLevel(key) == self.level) {
                return key[2..];
            }
        }

        return null;
    }

    pub fn goToLast(self: *SkipListCursor, level: u16) ![]const u8 {
        try self.goToNode(level + 1, &[_]u8 {});

        self.level = level;
        if (try self.cursor.goToPrevious()) |previous_key| {
            if (utils.getLevel(previous_key) == level) {
                return previous_key[2..];
            }
        }

        return error.KeyNotFound;
    }

    pub fn get(self: *SkipListCursor, level: u16, key: []const u8) !?[]const u8 {
        try self.setKey(level, key);
        return self.txn.get(self.key.items);
    }

    pub fn set(self: *SkipListCursor, level: u16, key: []const u8, value: []const u8) !void {
        try self.setKey(level, key);
        try self.txn.set(self.key.items, value);
    }

    pub fn delete(self: *SkipListCursor, level: u16, key: []const u8) !void {
        try self.setKey(level, key);
        try self.txn.delete(self.key.items);
    }

    pub fn deleteCurrentKey(self: *SkipListCursor) !void {
        try self.cursor.deleteCurrentKey();
    }
    
    // pub fn isSplit() {
        
    // }
    
    // fn printPrefix(writer: std.fs.File.Writer, depth: u16) !void {
    //     var i: u16 = 0;
    //     while (i < depth + 1) : (i += 1) try self.writer.print("          ", .{});
    // }
    
    // fn printNode(self: *SkipListCursor, writer: std.fs.File.Writer, depth: u16, level: u16, key: []const u8) !void {
    //     try self.goToNode(level, key);

    //     const value = try self.cursor.getCurrentValue();
    //     assert(value.len == 32);
    //     try SkipListCursor.printPrefix(writer, depth);
    //     try self.writer.print("...{s} ", .{ hex(value[value.len-3..])});
        
    //     assert(level > 0);
    //     if (level == 1) {
    //         try self.goToNode(0, key);
    //         while (try self.goToNext(0)) |leaf| {
    //             const leaf_value = try cursor.getCurrentValue();
    //             if (isSplit(leaf_value)) {
    //                 break;
    //             } else {
    //                 try SkipListCursor.printPrefix(writer, depth + 1);
    //                 try self.writer.print("...{s}\n", .{ hex(leaf_value[leaf_value.len-3..]) });
    //             }
    //         }
    //     } else {
            
    //     }
    // }
};

