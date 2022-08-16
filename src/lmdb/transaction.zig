const std = @import("std");

const Environment = @import("./environment.zig").Environment;

const lmdb = @import("./lmdb.zig").lmdb;

pub const Transaction = struct {
  pub const Error = error {
    LmdbTransactionError,
    KeyNotFound
  };

  ptr: ?*lmdb.MDB_txn,
  readOnly: bool,

  pub fn open(env: Environment, readOnly: bool) !Transaction {
    var txn = Transaction{ .ptr = null, .readOnly = readOnly };
    const flags: c_uint = if (readOnly) lmdb.MDB_RDONLY else 0;
    try switch (lmdb.mdb_txn_begin(env.ptr, null, flags, &txn.ptr)) {
      0 => {},
      // lmdb.MDB_PANIC => Error.LmdbPanic,
      // lmdb.MDB_MAP_RESIZED => Error.LmdbMapResized,
      // lmdb.MDB_READERS_FULL => Error.LmdbReadersFull,
      // @enumToInt(std.os.E.NOMEM) => std.os.E.NOMEM,
      else => Error.LmdbTransactionError,
    };

    return txn;
  }

  pub fn openDbi(self: *Transaction) !lmdb.MDB_dbi {
    var dbi: lmdb.MDB_dbi = 0;
    const flags: c_uint = if (self.readOnly) 0 else lmdb.MDB_CREATE;
    try switch (lmdb.mdb_dbi_open(self.ptr, null, flags, &dbi)) {
      0 => {},
      else => Error.LmdbTransactionError,
    };

    return dbi;
  }

  pub fn commit(self: *Transaction) !void {
    try switch (lmdb.mdb_txn_commit(self.ptr)) {
      0 => {},
      // @enumToInt(std.os.E.INVAL) => std.os.E.INVAL,
      // @enumToInt(std.os.E.NOSPC) => std.os.E.NOSPC,
      // @enumToInt(std.os.E.IO) => std.os.E.IO,
      // @enumToInt(std.os.E.NOMEM) => std.os.E.NOMEM,
      else => Error.LmdbTransactionError,
    };
    self.ptr = null;
  }

  pub fn abort(self: *Transaction) void {
    lmdb.mdb_txn_abort(self.ptr);
    self.ptr = null;
  }

  pub fn get(self: *Transaction, dbi: lmdb.MDB_dbi, key: []const u8) !?[]const u8 {
    var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @intToPtr([*]u8, @ptrToInt(key.ptr)) };
    var v: lmdb.MDB_val = .{ .mv_size = 0, .mv_data = null };
    const err = lmdb.mdb_get(self.ptr, dbi, &k, &v);
    if (err == 0) {
      return @ptrCast([*]u8, v.mv_data)[0..v.mv_size];
    } else if (err == lmdb.MDB_NOTFOUND) {
      return null;
    } else {
      return Error.LmdbTransactionError;
    }
  }

  pub fn set(self: *Transaction, dbi: lmdb.MDB_dbi, key: []const u8, value: []const u8) !void {
    var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @intToPtr([*]u8, @ptrToInt(key.ptr)) };
    var v: lmdb.MDB_val = .{ .mv_size = value.len, .mv_data = @intToPtr([*]u8, @ptrToInt(value.ptr)) };
    try switch (lmdb.mdb_put(self.ptr, dbi, &k, &v, 0)) {
      0 => {},
      lmdb.MDB_NOTFOUND => Error.KeyNotFound,
      else => Error.LmdbTransactionError,
    };
  }

  pub fn delete(self: *Transaction, dbi: lmdb.MDB_dbi, key: []const u8) !void {
    var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @intToPtr([*]u8, @ptrToInt(key.ptr)) };
    try switch (lmdb.mdb_del(self.ptr, dbi, &k, null)) {
      0 => {},
      else => Error.LmdbTransactionError,
    };
  }
};