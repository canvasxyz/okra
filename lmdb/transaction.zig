const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const Environment = @import("environment.zig").Environment;
const lmdb = @import("lmdb.zig");

pub const Transaction = struct {
    pub const Options = struct {
        read_only: bool = true,
        dbi: ?[*:0]const u8 = null,
        parent: ?Transaction = null,
    };

    ptr: ?*lmdb.MDB_txn,
    dbi: lmdb.MDB_dbi,

    pub fn open(env: Environment, options: Options) !Transaction {
        var txn = Transaction{ .ptr = null, .dbi = 0 };

        {
            var flags: c_uint = 0;
            if (options.read_only) {
                flags |= lmdb.MDB_RDONLY;
            }

            var parentPtr: ?*lmdb.MDB_txn = null;
            if (options.parent) |parent| {
                parentPtr = parent.ptr;
            }

            try switch (lmdb.mdb_txn_begin(env.ptr, parentPtr, flags, &txn.ptr)) {
                0 => {},
                @intFromEnum(std.os.E.ACCES) => error.ACCES,
                @intFromEnum(std.os.E.NOMEM) => error.NOMEM,
                lmdb.MDB_PANIC => error.LmdbPanic,
                lmdb.MDB_BAD_TXN => error.LmdbInvalidTransaction,
                lmdb.MDB_MAP_RESIZED => error.LmdbMapResized,
                lmdb.MDB_READERS_FULL => error.LmdbReadersFull,
                lmdb.MDB_BAD_RSLOT => error.LmdbBadReaderSlot,
                else => error.LmdbTransactionBeginError,
            };
        }

        {
            const flags: c_uint = if (options.read_only) 0 else lmdb.MDB_CREATE;
            try switch (lmdb.mdb_dbi_open(txn.ptr, options.dbi, flags, &txn.dbi)) {
                0 => {},
                lmdb.MDB_NOTFOUND => error.LmdbDbiNotFound,
                lmdb.MDB_DBS_FULL => error.LmdbDbsFull,
                else => error.LmdbDbiOpenError,
            };
        }

        return txn;
    }

    pub fn commit(self: Transaction) !void {
        try switch (lmdb.mdb_txn_commit(self.ptr)) {
            0 => {},
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            @intFromEnum(std.os.E.NOSPC) => error.NOSPC,
            @intFromEnum(std.os.E.IO) => error.IO,
            @intFromEnum(std.os.E.NOMEM) => error.NOMEM,
            else => error.LmdbTransactionCommitError,
        };
    }

    pub fn abort(self: Transaction) void {
        lmdb.mdb_txn_abort(self.ptr);
    }

    pub fn get(self: Transaction, key: []const u8) !?[]const u8 {
        var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(key.ptr))) };
        var v: lmdb.MDB_val = .{ .mv_size = 0, .mv_data = null };
        return switch (lmdb.mdb_get(self.ptr, self.dbi, &k, &v)) {
            0 => @as([*]u8, @ptrCast(v.mv_data))[0..v.mv_size],
            lmdb.MDB_NOTFOUND => null,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbTransactionGetError,
        };
    }

    pub fn set(self: Transaction, key: []const u8, value: []const u8) !void {
        var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(key.ptr))) };
        var v: lmdb.MDB_val = .{ .mv_size = value.len, .mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(value.ptr))) };
        try switch (lmdb.mdb_put(self.ptr, self.dbi, &k, &v, 0)) {
            0 => {},
            lmdb.MDB_MAP_FULL => error.LmdbMapFull,
            lmdb.MDB_TXN_FULL => error.LmdbTxnFull,
            @intFromEnum(std.os.E.ACCES) => error.ACCES,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbTransactionSetError,
        };
    }

    pub fn delete(self: Transaction, key: []const u8) !void {
        var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(key.ptr))) };
        try switch (lmdb.mdb_del(self.ptr, self.dbi, &k, null)) {
            0 => {},
            lmdb.MDB_NOTFOUND => error.KeyNotFound,
            @intFromEnum(std.os.E.ACCES) => error.ACCES,
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbTransactionDeleteError,
        };
    }
};
