const std = @import("std");

const Environment = @import("./environment.zig").Environment;
const lmdb = @import("./lmdb.zig");

pub fn Transaction(comptime K: usize, comptime V: usize) type {
  return struct {
    pub const Error = error {
      LmdbTransactionError,
      KeyNotFound,
      InvalidKeySize,
      InvalidValueSize,
    };

    ptr: ?*lmdb.MDB_txn,
    readOnly: bool,

    pub fn open(env: Environment(K, V), readOnly: bool) !Transaction(K, V) {
      var txn = Transaction(K, V){ .ptr = null, .readOnly = readOnly };
      const flags: c_uint = if (readOnly) lmdb.MDB_RDONLY else 0;
      try switch (lmdb.mdb_txn_begin(env.ptr, null, flags, &txn.ptr)) {
        0 => {},
        else => Error.LmdbTransactionError,
      };

      return txn;
    }

    pub fn openDBI(self: *Transaction(K, V)) !lmdb.MDB_dbi {
      var dbi: lmdb.MDB_dbi = 0;
      const flags: c_uint = if (self.readOnly) 0 else lmdb.MDB_CREATE;
      try switch (lmdb.mdb_dbi_open(self.ptr, null, flags, &dbi)) {
        0 => {},
        else => Error.LmdbTransactionError,
      };

      return dbi;
    }

    pub fn commit(self: *Transaction(K, V)) !void {
      try switch (lmdb.mdb_txn_commit(self.ptr)) {
        0 => {},
        else => Error.LmdbTransactionError,
      };
      self.ptr = null;
    }

    pub fn abort(self: *Transaction(K, V)) void {
      lmdb.mdb_txn_abort(self.ptr);
      self.ptr = null;
    }

    pub fn get(self: *Transaction(K, V), dbi: lmdb.MDB_dbi, key: *const [K]u8) !?*[V]u8 {
      var k: lmdb.MDB_val = .{ .mv_size = K, .mv_data = @intToPtr([*]u8, @ptrToInt(key)) };
      var v: lmdb.MDB_val = .{ .mv_size = 0, .mv_data = null };
      const err = lmdb.mdb_get(self.ptr, dbi, &k, &v);
      if (err == 0) {
        return if (v.mv_size == V) @ptrCast(*[V]u8, v.mv_data) else Error.InvalidValueSize;
      } else if (err == lmdb.MDB_NOTFOUND) {
        return null;
      } else {
        return Error.LmdbTransactionError;
      }
    }

    pub fn set(self: *Transaction(K, V), dbi: lmdb.MDB_dbi, key: *const [K]u8, value: *const [V]u8) !void {
      var k: lmdb.MDB_val = .{ .mv_size = K, .mv_data = @intToPtr([*]u8, @ptrToInt(key)) };
      var v: lmdb.MDB_val = .{ .mv_size = V, .mv_data = @intToPtr([*]u8, @ptrToInt(value)) };
      try switch (lmdb.mdb_put(self.ptr, dbi, &k, &v, 0)) {
        0 => {},
        lmdb.MDB_NOTFOUND => Error.KeyNotFound,
        else => Error.LmdbTransactionError,
      };
    }

    pub fn delete(self: *Transaction(K, V), dbi: lmdb.MDB_dbi, key: *const [K]u8) !void {
      var k: lmdb.MDB_val = .{ .mv_size = K, .mv_data = @intToPtr([*]u8, @ptrToInt(key)) };
      try switch (lmdb.mdb_del(self.ptr, dbi, &k, null)) {
        0 => {},
        lmdb.MDB_NOTFOUND => Error.KeyNotFound,
        else => Error.LmdbTransactionError,
      };
    }
  };
} 