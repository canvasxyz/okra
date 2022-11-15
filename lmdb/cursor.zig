const std = @import("std");
const assert = std.debug.assert;

const lmdb = @import("./lmdb.zig");

const Transaction = @import("./transaction.zig").Transaction;

pub const Cursor = struct {
    pub const Error = error { LmdbCursorError, InvalidKeySize, InvalidValueSize, KeyNotFound };

    ptr: ?*lmdb.MDB_cursor,

    pub fn open(txn: Transaction) !Cursor {
        var cursor = Cursor { .ptr = null };

        try switch (lmdb.mdb_cursor_open(txn.ptr, txn.dbi, &cursor.ptr)) {
            0 => {},
            else => Error.LmdbCursorError,
        };

        return cursor;
    }

    pub fn close(self: Cursor) void {
        lmdb.mdb_cursor_close(self.ptr);
    }

    pub fn getCurrentKey(self: Cursor) ![]const u8 {
        var slice: lmdb.MDB_val = undefined;
        try switch (lmdb.mdb_cursor_get(self.ptr, &slice, null, lmdb.MDB_GET_CURRENT)) {
            0 => {},
            else => Error.LmdbCursorError,
        };

        return @ptrCast([*]u8, slice.mv_data)[0..slice.mv_size];
    }

    pub fn getCurrentValue(self: Cursor) ![]const u8 {
        var slice: lmdb.MDB_val = undefined;
        try switch (lmdb.mdb_cursor_get(self.ptr, null, &slice, lmdb.MDB_GET_CURRENT)) {
            0 => {},
            else => Error.LmdbCursorError,
        };

        return @ptrCast([*]u8, slice.mv_data)[0..slice.mv_size];
    }

    pub fn deleteCurrentKey(self: Cursor) !void {
        try switch (lmdb.mdb_cursor_del(self.ptr, 0)) {
            0 => {},
            else => Error.LmdbCursorError,
        };
    }

    pub fn goToNext(self: Cursor) !?[]const u8 {
        var slice: lmdb.MDB_val = undefined;
        const err = lmdb.mdb_cursor_get(self.ptr, &slice, null, lmdb.MDB_NEXT);
        if (err == 0) {
            return @ptrCast([*]u8, slice.mv_data)[0..slice.mv_size];
        } else if (err == lmdb.MDB_NOTFOUND) {
            return null;
        } else {
            return Error.LmdbCursorError;
        }
    }

    pub fn goToPrevious(self: Cursor) !?[]const u8 {
        var slice: lmdb.MDB_val = undefined;
        const err = lmdb.mdb_cursor_get(self.ptr, &slice, null, lmdb.MDB_PREV);
        if (err == 0) {
            return @ptrCast([*]u8, slice.mv_data)[0..slice.mv_size];
        } else if (err == lmdb.MDB_NOTFOUND) {
            return null;
        } else {
            return Error.LmdbCursorError;
        }
    }

    pub fn goToLast(self: Cursor) !?[]const u8 {
        var slice: lmdb.MDB_val = undefined;
        const err = lmdb.mdb_cursor_get(self.ptr, &slice, null, lmdb.MDB_LAST);
        if (err == 0) {
            return @ptrCast([*]u8, slice.mv_data)[0..slice.mv_size];
        } else if (err == lmdb.MDB_NOTFOUND) {
            return null;
        } else {
            return Error.LmdbCursorError;
        }
    }

    pub fn goToFirst(self: Cursor) !?[]const u8 {
        var slice: lmdb.MDB_val = undefined;
        const err = lmdb.mdb_cursor_get(self.ptr, &slice, null, lmdb.MDB_FIRST);
        if (err == 0) {
            return @ptrCast([*]u8, slice.mv_data)[0..slice.mv_size];
        } else if (err == lmdb.MDB_NOTFOUND) {
            return null;
        } else {
            return Error.LmdbCursorError;
        }
    }

    pub fn goToKey(self: Cursor, key: []const u8) !void {
        var slice: lmdb.MDB_val = undefined;
        slice.mv_size = key.len;
        slice.mv_data = @intToPtr([*]u8, @ptrToInt(key.ptr));
        const err = lmdb.mdb_cursor_get(self.ptr, &slice, null, lmdb.MDB_SET_KEY);
        if (err == 0) {
            return;
        } else if (err == lmdb.MDB_NOTFOUND) {
            return Error.KeyNotFound;
        } else {
            return Error.LmdbCursorError;
        }
    }
};