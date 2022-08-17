const std = @import("std");
const assert = std.debug.assert;

const lmdb = @import("./lmdb.zig").lmdb;

const Transaction = @import("./transaction.zig").Transaction;

pub fn Cursor(comptime K: usize, comptime V: usize) type {
  return struct {
    pub const Error = error {
      LmdbCursorError,
    };

    ptr: ?*lmdb.MDB_cursor,
    key: lmdb.MDB_val,
    value: lmdb.MDB_val,

    pub fn open(txn: Transaction(K, V), dbi: lmdb.MDB_dbi) !Cursor(K, V) {
      var cursor = Cursor(K, V){
        .ptr = null,
        .key = .{ .mv_size = 0, .mv_data = null },
        .value = .{ .mv_size = 0, .mv_data = null },
      };

      try switch (lmdb.mdb_cursor_open(txn.ptr, dbi, &cursor.ptr)) {
        0 => {},
        else => Error.LmdbCursorError,
      };

      return cursor;
    }

    pub fn close(self: *Cursor(K, V)) void {
      self.key.mv_size = 0;
      self.key.mv_data = null;
      self.value.mv_size = 0;
      self.value.mv_data = null;
      lmdb.mdb_cursor_close(self.ptr);
      self.ptr = null;
    }

    pub fn getCurrentKey(self: *const Cursor(K, V)) ?*const [K]u8 {
      if (self.key.mv_data == null) {
        return null;
      } else {
        assert(self.key.mv_size == K);
        return @ptrCast(*const [K]u8, self.key.mv_data);
      }
    }

    pub fn getCurrentValue(self: *const Cursor(K, V)) ?*const [V]u8 {
      if (self.value.mv_data == null) {
        return null;
      } else {
        assert(self.value.mv_size == V);
        return @ptrCast(*const [V]u8, self.value.mv_data);
      }
    }

    pub fn deleteCurrentKey(self: *Cursor(K, V)) !void {
      self.key.mv_size = 0;
      self.key.mv_data = null;
      self.value.mv_size = 0;
      self.value.mv_data = null;
      try switch (lmdb.mdb_cursor_del(self.ptr, 0)) {
        0 => {},
        else => Error.LmdbCursorError,
      };
    }

    // pub fn setCurrentValue(self: *Cursor(K, V), value: *const [V]u8) !void {
    //   self.value.mv_size = V;
    //   self.value.data = value;
    //   try switch(lmdb.mdb_cursor_put(self.ptr, &self.key, &self.value, lmdb.MDB_CURRENT)) {
    //     0 => {},
    //     // lmdb.MDB_MAP_FULL => 
    //     // lmdb.MDB_TXN_FULL => 
    //     else => Error.LmdbCursorError,
    //   };
    // }

    pub fn goToNext(self: *Cursor(K, V)) !?*const [K]u8 {
      const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_NEXT);
      if (err == 0) {
        return self.getCurrentKey();
      } else if (err == lmdb.MDB_NOTFOUND) {
        return null;
      } else {
        return Error.LmdbCursorError;
      }
    }

    pub fn goToPrevious(self: *Cursor(K, V)) !?*const [K]u8 {
      const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_PREV);
      if (err == 0) {
        return self.getCurrentKey();
      } else if (err == lmdb.MDB_NOTFOUND) {
        return null;
      } else {
        return Error.LmdbCursorError;
      }
    }

    pub fn goToLast(self: *Cursor(K, V)) !?*const [K]u8 {
      const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_LAST);
      if (err == 0) {
        return self.getCurrentKey();
      } else if (err == lmdb.MDB_NOTFOUND) {
        return null;
      } else {
        return Error.LmdbCursorError;
      }
    }

    pub fn goToFirst(self: *Cursor(K, V)) !?*const [K]u8 {
      const err = lmdb.mdb_cursor_get(self.ptr, &self.key, &self.value, lmdb.MDB_FIRST);
      if (err == 0) {
        return self.getCurrentKey();
      } else if (err == lmdb.MDB_NOTFOUND) {
        return null;
      } else {
        return Error.LmdbCursorError;
      }
    }

    pub fn goToKey(self: *Cursor(K, V), key: *const [K]u8) !?*const [K]u8 {
      self.key.mv_size = K;
      self.key.mv_data = @intToPtr([*]u8, @ptrToInt(key));
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
}