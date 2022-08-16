const std = @import("std");

const lmdb = @import("./lmdb.zig").lmdb;

const Transaction = @import("./transaction.zig").Transaction;

pub const Cursor = struct {
  pub const Error = error {
    LmdbCursorError,
  };

  ptr: ?*lmdb.MDB_cursor,
  key: lmdb.MDB_val,
  value: lmdb.MDB_val,

  pub fn open(txn: Transaction, dbi: lmdb.MDB_dbi) !Cursor {
    var cursor = Cursor{
      .ptr = null,
      .key = .{ .mv_size = 0, .mv_data = null },
      .value = .{ .mv_size = 0, .mv_data = null },
    };

    try switch (lmdb.mdb_cursor_open(txn.ptr, dbi, &cursor.ptr)) {
      0 => {},
      // @enumToInt(std.os.E.INVAL) => std.os.E.INVAL,
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

  pub fn getCurrentKey(self: *const Cursor) ?[]const u8 {
    const size = self.key.mv_size;
    const data = self.key.mv_data;
    if (size == 0 or data == null) {
      return null;
    } else {
      return @ptrCast([*]const u8, data)[0..size];
    }
  }

  pub fn getCurrentValue(self: *const Cursor) ?[]const u8 {
    const size = self.value.mv_size;
    const data = self.value.mv_data;
    if (size == 0 or data == null) {
      return null;
    } else {
      return @ptrCast([*]const u8, data)[0..size];
    }
  }

  pub fn deleteCurrentKey(self: *Cursor) !void {
    self.key.mv_size = 0;
    self.key.mv_data = null;
    self.value.mv_size = 0;
    self.value.mv_data = null;
    try switch (lmdb.mdb_cursor_del(self.ptr, 0)) {
      0 => {},
      // @enumToInt(std.os.E.ACCES) => std.os.E.ACCES,
      // @enumToInt(std.os.E.INVAL) => std.os.E.INVAL,
      else => Error.LmdbCursorError,
    };
  }

  pub fn setCurrentValue(self: *Cursor, value: []const u8) !void {
    self.value.mv_size = value.len;
    self.value.data = @intToPtr([*]u8, @ptrToInt(value.ptr));
    try switch(lmdb.mdb_cursor_put(self.ptr, &self.key, &self.value, lmdb.MDB_CURRENT)) {
      0 => {},
      // lmdb.MDB_MAP_FULL => 
      // lmdb.MDB_TXN_FULL => 
      // @enumToInt(std.os.E.ACCES) => std.os.E.ACCES,
      // @enumToInt(std.os.E.INVAL) => std.os.E.INVAL,
      else => Error.LmdbCursorError,
    };
  }

  pub fn goToNext(self: *Cursor) !?[]const u8 {
    const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_NEXT);
    if (err == 0) {
      return self.getCurrentKey();
    } else if (err == lmdb.MDB_NOTFOUND) {
      return null;
    // } else if (err == @enumToInt(std.os.E.INVAL)) {
    //   return std.os.E.INVAL;
    } else {
      return Error.LmdbCursorError;
    }
  }

  pub fn goToPrevious(self: *Cursor) !?[]const u8 {
    const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_PREV);
    if (err == 0) {
      return self.getCurrentKey();
    } else if (err == lmdb.MDB_NOTFOUND) {
      return null;
    // } else if (err == @enumToInt(std.os.E.INVAL)) {
    //   return std.os.E.INVAL;
    } else {
      return Error.LmdbCursorError;
    }
  }

  pub fn goToLast(self: *Cursor) !?[]const u8 {
    const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_LAST);
    if (err == 0) {
      return self.getCurrentKey();
    } else if (err == lmdb.MDB_NOTFOUND) {
      return null;
    // } else if (err == @enumToInt(std.os.E.INVAL)) {
    //   return std.os.E.INVAL;
    } else {
      return Error.LmdbCursorError;
    }
  }

  pub fn goToFirst(self: *Cursor) !?[]const u8 {
    const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_FIRST);
    if (err == 0) {
      return self.getCurrentKey();
    } else if (err == lmdb.MDB_NOTFOUND) {
      return null;
    // } else if (err == @enumToInt(std.os.E.INVAL)) {
    //   return std.os.E.INVAL;
    } else {
      return Error.LmdbCursorError;
    }
  }

  pub fn goToKey(self: *Cursor, key: []const u8) !?[]const u8 {
    self.key.mv_size = key.len;
    self.key.mv_data = @intToPtr([*]u8, @ptrToInt(key.ptr));
    const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_SET_KEY);
    if (err == 0) {
      return self.getCurrentKey();
    } else if (err == lmdb.MDB_NOTFOUND) {
      return null;
    } else {
      return Error.LmdbCursorError;
    }
  }
};