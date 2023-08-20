const std = @import("std");
const assert = std.debug.assert;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb.zig");

const Transaction = @import("transaction.zig").Transaction;

pub const Cursor = struct {
    ptr: ?*lmdb.MDB_cursor,

    pub fn open(txn: Transaction) !Cursor {
        var cursor = Cursor{ .ptr = null };

        try switch (lmdb.mdb_cursor_open(txn.ptr, txn.dbi, &cursor.ptr)) {
            0 => {},
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorOpenError,
        };

        return cursor;
    }

    pub fn close(self: Cursor) void {
        lmdb.mdb_cursor_close(self.ptr);
    }

    pub const Entry = struct { key: []const u8, value: []const u8 };

    pub fn getCurrentEntry(self: Cursor) !Entry {
        var k: lmdb.MDB_val = undefined;
        var v: lmdb.MDB_val = undefined;
        return switch (lmdb.mdb_cursor_get(self.ptr, &k, &v, lmdb.MDB_GET_CURRENT)) {
            0 => .{
                .key = @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size],
                .value = @as([*]u8, @ptrCast(v.mv_data))[0..v.mv_size],
            },
            lmdb.MDB_NOTFOUND => error.KeyNotFound,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorGetError,
        };
    }

    pub fn getCurrentKey(self: Cursor) ![]const u8 {
        var slice: lmdb.MDB_val = undefined;
        return switch (lmdb.mdb_cursor_get(self.ptr, &slice, null, lmdb.MDB_GET_CURRENT)) {
            0 => @as([*]u8, @ptrCast(slice.mv_data))[0..slice.mv_size],
            lmdb.MDB_NOTFOUND => error.KeyNotFound,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorError,
        };
    }

    pub fn getCurrentValue(self: Cursor) ![]const u8 {
        var v: lmdb.MDB_val = undefined;
        return switch (lmdb.mdb_cursor_get(self.ptr, null, &v, lmdb.MDB_GET_CURRENT)) {
            0 => @as([*]u8, @ptrCast(v.mv_data))[0..v.mv_size],
            lmdb.MDB_NOTFOUND => error.KeyNotFound,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorGetError,
        };
    }

    pub fn setCurrentValue(self: Cursor, value: []const u8) !void {
        var k: lmdb.MDB_val = undefined;
        try switch (lmdb.mdb_cursor_get(self.ptr, &k, null, lmdb.MDB_GET_CURRENT)) {
            0 => {},
            lmdb.MDB_NOTFOUND => error.KeyNotFound,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorError,
        };

        var v: lmdb.MDB_val = .{ .mv_size = value.len, .mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(value.ptr))) };
        try switch (lmdb.mdb_cursor_put(self.ptr, &k, &v, lmdb.MDB_CURRENT)) {
            0 => {},
            lmdb.MDB_MAP_FULL => error.LmdbMapFull,
            lmdb.MDB_TXN_FULL => error.LmdbTxnFull,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            @intFromEnum(std.os.E.ACCES) => error.ACCES,
            else => error.LmdbCursorError,
        };
    }

    pub fn deleteCurrentKey(self: Cursor) !void {
        try switch (lmdb.mdb_cursor_del(self.ptr, 0)) {
            0 => {},
            @intFromEnum(std.os.E.ACCES) => error.ACCES,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorDeleteError,
        };
    }

    pub fn goToNext(self: Cursor) !?[]const u8 {
        var k: lmdb.MDB_val = undefined;
        return switch (lmdb.mdb_cursor_get(self.ptr, &k, null, lmdb.MDB_NEXT)) {
            0 => @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size],
            lmdb.MDB_NOTFOUND => null,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorGetError,
        };
    }

    pub fn goToPrevious(self: Cursor) !?[]const u8 {
        var k: lmdb.MDB_val = undefined;
        return switch (lmdb.mdb_cursor_get(self.ptr, &k, null, lmdb.MDB_PREV)) {
            0 => @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size],
            lmdb.MDB_NOTFOUND => null,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorGetError,
        };
    }

    pub fn goToLast(self: Cursor) !?[]const u8 {
        var k: lmdb.MDB_val = undefined;
        return switch (lmdb.mdb_cursor_get(self.ptr, &k, null, lmdb.MDB_LAST)) {
            0 => @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size],
            lmdb.MDB_NOTFOUND => null,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorGetError,
        };
    }

    pub fn goToFirst(self: Cursor) !?[]const u8 {
        var k: lmdb.MDB_val = undefined;
        return switch (lmdb.mdb_cursor_get(self.ptr, &k, null, lmdb.MDB_FIRST)) {
            0 => @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size],
            lmdb.MDB_NOTFOUND => null,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorGetError,
        };
    }

    pub fn goToKey(self: Cursor, key: []const u8) !void {
        var k: lmdb.MDB_val = undefined;
        k.mv_size = key.len;
        k.mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(key.ptr)));
        try switch (lmdb.mdb_cursor_get(self.ptr, &k, null, lmdb.MDB_SET_KEY)) {
            0 => {},
            lmdb.MDB_NOTFOUND => error.KeyNotFound,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorGetError,
        };
    }

    pub fn seek(self: Cursor, key: []const u8) !?[]const u8 {
        var k: lmdb.MDB_val = undefined;
        k.mv_size = key.len;
        k.mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(key.ptr)));
        return switch (lmdb.mdb_cursor_get(self.ptr, &k, null, lmdb.MDB_SET_RANGE)) {
            0 => @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size],
            lmdb.MDB_NOTFOUND => null,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbCursorGetError,
        };
    }
};
