const std = @import("std");
const assert = std.debug.assert;

const lmdb = @import("./lmdb.zig");

const Transaction = @import("./transaction.zig").Transaction;

pub const Cursor = struct {
    pub const Error = error { LmdbCursorError, InvalidKeySize, InvalidValueSize, KeyNotFound };

    ptr: ?*lmdb.MDB_cursor,
    key: lmdb.MDB_val,
    value: lmdb.MDB_val,

    pub fn open(txn: Transaction) !Cursor {
        var cursor = Cursor {
            .ptr = null,
            .key = .{ .mv_size = 0, .mv_data = null },
            .value = .{ .mv_size = 0, .mv_data = null },
        };

        try switch (lmdb.mdb_cursor_open(txn.ptr, txn.dbi, &cursor.ptr)) {
            0 => {},
            else => Error.LmdbCursorError,
        };

        return cursor;
    }

    pub fn close(self: *Cursor) void {
        self.key.mv_size = 0;
        self.key.mv_data = null;
        self.value.mv_size = 0;
        self.value.mv_data = null;
        lmdb.mdb_cursor_close(self.ptr);
        self.ptr = null;
    }

    pub fn getCurrentKey(self: *const Cursor) ![]const u8 {
        if (self.key.mv_data == null) {
            return Error.KeyNotFound;
        } else {
            return @ptrCast([*]u8, self.key.mv_data)[0..self.key.mv_size];
        }
    }

    pub fn getCurrentValue(self: *const Cursor) ![]const u8 {
        if (self.value.mv_data == null) {
            return Error.KeyNotFound;
        } else {
            return @ptrCast([*]u8, self.value.mv_data)[0..self.value.mv_size];
        }
    }

    pub fn deleteCurrentKey(self: *Cursor) !void {
        self.key.mv_size = 0;
        self.key.mv_data = null;
        self.value.mv_size = 0;
        self.value.mv_data = null;
        try switch (lmdb.mdb_cursor_del(self.ptr, 0)) {
            0 => {},
            else => Error.LmdbCursorError,
        };
    }

    pub fn goToNext(self: *Cursor) !?[]const u8 {
        const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_NEXT);
        if (err == 0) {
            return try self.getCurrentKey();
        } else if (err == lmdb.MDB_NOTFOUND) {
            return null;
        } else {
            return Error.LmdbCursorError;
        }
    }

    pub fn goToPrevious(self: *Cursor) !?[]const u8 {
        const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_PREV);
        if (err == 0) {
            return try self.getCurrentKey();
        } else if (err == lmdb.MDB_NOTFOUND) {
            return null;
        } else {
            return Error.LmdbCursorError;
        }
    }

    pub fn goToLast(self: *Cursor) !?[]const u8 {
        const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_LAST);
        if (err == 0) {
            return try self.getCurrentKey();
        } else if (err == lmdb.MDB_NOTFOUND) {
            return null;
        } else {
            return Error.LmdbCursorError;
        }
    }

    pub fn goToFirst(self: *Cursor) !?[]const u8 {
        const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_FIRST);
        if (err == 0) {
            return try self.getCurrentKey();
        } else if (err == lmdb.MDB_NOTFOUND) {
            return null;
        } else {
            return Error.LmdbCursorError;
        }
    }

    pub fn goToKey(self: *Cursor, key: []const u8) !void {
        self.key.mv_size = key.len;
        self.key.mv_data = @intToPtr([*]u8, @ptrToInt(key.ptr));
        const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_SET_KEY);
        if (err == 0) {
            return;
        } else if (err == lmdb.MDB_NOTFOUND) {
            return Error.KeyNotFound;
        } else {
            return Error.LmdbCursorError;
        }
    }
};