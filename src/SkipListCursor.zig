const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;

const lmdb = @import("lmdb");

const utils = @import("utils.zig");

pub const SkipListCursor = struct {
    key: std.ArrayList(u8),
    txn: lmdb.Transaction,
    cursor: lmdb.Cursor,

    pub fn open(allocator: std.mem.Allocator, env: lmdb.Environment, read_only: bool) !SkipListCursor {
        const key = std.ArrayList(u8).init(allocator);
        errdefer key.deinit();

        const txn = try lmdb.Transaction.open(env, read_only);
        errdefer txn.abort();

        const cursor = try lmdb.Cursor.open(txn);
        return SkipListCursor{ .key = key, .txn = txn, .cursor = cursor };
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
        return key[1..];
    }

    pub fn getCurrentValue(self: *SkipListCursor) ![]const u8 {
        return self.cursor.getCurrentValue();
    }

    fn setKey(self: *SkipListCursor, level: u8, key: []const u8) !void {
        try self.key.resize(1 + key.len);
        self.key.items[0] = level;
        std.mem.copy(u8, self.key.items[1..], key);
    }

    pub fn goToNode(self: *SkipListCursor, level: u8, key: []const u8) !void {
        try self.setKey(level, key);
        try self.cursor.goToKey(self.key.items);
    }

    pub fn goToNext(self: *SkipListCursor, level: u8) !?[]const u8 {
        if (try self.cursor.goToNext()) |key| {
            if (key[0] == level) {
                return key[1..];
            }
        }

        return null;
    }

    pub fn goToPrevious(self: *SkipListCursor, level: u8) !?[]const u8 {
        if (try self.cursor.goToPrevious()) |key| {
            if (key[0] == level) {
                return key[1..];
            }
        }

        return null;
    }

    pub fn goToLast(self: *SkipListCursor, level: u8) ![]const u8 {
        try self.goToNode(level + 1, &[_]u8{});

        if (try self.cursor.goToPrevious()) |previous_key| {
            if (previous_key[0] == level) {
                return previous_key[1..];
            }
        }

        return error.KeyNotFound;
    }

    pub fn get(self: *SkipListCursor, level: u8, key: []const u8) !?[]const u8 {
        try self.setKey(level, key);
        return self.txn.get(self.key.items);
    }

    pub fn set(self: *SkipListCursor, level: u8, key: []const u8, value: []const u8) !void {
        // if (level == 1 and std.mem.eql(u8, key, &[_]u8{ 0x01, 0x07 })) {
        //     std.log.err("AAAAAAAA HOLY SHITTTTT {s}", .{hex(value)});
        // }

        try self.setKey(level, key);
        try self.txn.set(self.key.items, value);
    }

    pub fn delete(self: *SkipListCursor, level: u8, key: []const u8) !void {
        // std.log.err("DELETING THE KEY {d} {s}", .{ level, hex(key) });
        // if (level == 1 and std.mem.eql(u8, key, &[_]u8{ 0x01, 0x07 })) {
        //     return error.WHAT_THE_FUCK;
        // }

        try self.setKey(level, key);
        try self.txn.delete(self.key.items);
    }

    pub fn deleteCurrentKey(self: *SkipListCursor) !void {
        // const key = try self.cursor.getCurrentKey();
        // std.log.err("DELETING KEY {d} {s}", .{ key[0], hex(key[1..]) });
        // if (std.mem.eql(u8, key, &[_]u8{ 0x01, 0x01, 0x07 })) {
        //     return error.WHAT_THE_FUCK;
        // }

        try self.cursor.deleteCurrentKey();
    }
};
