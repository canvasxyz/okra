const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const Environment = @import("environment.zig").Environment;
const lmdb = @import("lmdb.zig");

pub const Transaction = struct {
    pub const Options = struct {
        read_only: bool = true,
    };

    pub const Error = error{
        LmdbTransactionError,
        KeyNotFound,
        InvalidKeySize,
        InvalidValueSize,
    };

    ptr: ?*lmdb.MDB_txn,
    dbi: lmdb.MDB_dbi,

    pub fn open(env: Environment, options: Options) !Transaction {
        var txn = Transaction{ .ptr = null, .dbi = 0 };

        {
            const flags: c_uint = if (options.read_only) lmdb.MDB_RDONLY else 0;
            try switch (lmdb.mdb_txn_begin(env.ptr, null, flags, &txn.ptr)) {
                0 => {},
                else => Error.LmdbTransactionError,
            };
        }

        {
            const flags: c_uint = if (options.read_only) 0 else lmdb.MDB_CREATE;
            try switch (lmdb.mdb_dbi_open(txn.ptr, null, flags, &txn.dbi)) {
                0 => {},
                else => Error.LmdbTransactionError,
            };
        }

        return txn;
    }

    pub fn commit(self: Transaction) !void {
        try switch (lmdb.mdb_txn_commit(self.ptr)) {
            0 => {},
            else => Error.LmdbTransactionError,
        };
    }

    pub fn abort(self: Transaction) void {
        lmdb.mdb_txn_abort(self.ptr);
    }

    pub fn get(self: Transaction, key: []const u8) !?[]const u8 {
        var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @intToPtr([*]u8, @ptrToInt(key.ptr)) };
        var v: lmdb.MDB_val = .{ .mv_size = 0, .mv_data = null };
        const err = lmdb.mdb_get(self.ptr, self.dbi, &k, &v);
        if (err == 0) {
            return @ptrCast([*]u8, v.mv_data)[0..v.mv_size];
        } else if (err == lmdb.MDB_NOTFOUND) {
            return null;
        } else {
            return Error.LmdbTransactionError;
        }
    }

    pub fn set(self: Transaction, key: []const u8, value: []const u8) !void {
        var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @intToPtr([*]u8, @ptrToInt(key.ptr)) };
        var v: lmdb.MDB_val = .{ .mv_size = value.len, .mv_data = @intToPtr([*]u8, @ptrToInt(value.ptr)) };
        try switch (lmdb.mdb_put(self.ptr, self.dbi, &k, &v, 0)) {
            0 => {},
            lmdb.MDB_NOTFOUND => Error.KeyNotFound,
            else => Error.LmdbTransactionError,
        };
    }

    pub fn delete(self: Transaction, key: []const u8) !void {
        var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @intToPtr([*]u8, @ptrToInt(key.ptr)) };
        try switch (lmdb.mdb_del(self.ptr, self.dbi, &k, null)) {
            0 => {},
            lmdb.MDB_NOTFOUND => Error.KeyNotFound,
            else => Error.LmdbTransactionError,
        };
    }
};
