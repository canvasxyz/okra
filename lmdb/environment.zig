const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb.zig");

pub const Environment = struct {
    pub const Options = struct {
        map_size: usize = 10485760,
        max_dbs: u32 = 0,
        mode: u16 = 0o664,
        flags: u32 = lmdb.MDB_WRITEMAP,
    };

    pub const Error = error{
        LmdbVersionMismatch,
        LmdbEnvironmentError,
        LmdbCorruptDatabase,
        ACCES,
        NOENT,
        AGAIN,
    };

    ptr: ?*lmdb.MDB_env = null,

    pub fn open(path: [*:0]const u8, options: Options) !Environment {
        var env = Environment{};
        try switch (lmdb.mdb_env_create(&env.ptr)) {
            0 => {},
            else => error.LmdbEnvironmentCreateError,
        };

        try switch (lmdb.mdb_env_set_mapsize(env.ptr, options.map_size)) {
            0 => {},
            @enumToInt(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbEnvironmentError,
        };

        try switch (lmdb.mdb_env_set_maxdbs(env.ptr, options.max_dbs)) {
            0 => {},
            @enumToInt(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbEnvironmentError,
        };

        errdefer lmdb.mdb_env_close(env.ptr);
        try switch (lmdb.mdb_env_open(env.ptr, path, options.flags, options.mode)) {
            0 => {},
            lmdb.MDB_VERSION_MISMATCH => error.LmdbEnvironmentVersionMismatch,
            lmdb.MDB_INVALID => error.LmdbCorruptDatabase,
            @enumToInt(std.os.E.ACCES) => error.ACCES,
            @enumToInt(std.os.E.NOENT) => error.NOENT,
            @enumToInt(std.os.E.AGAIN) => error.AGAIN,
            else => error.LmdbEnvironmentError,
        };

        return env;
    }

    pub fn close(self: Environment) void {
        lmdb.mdb_env_close(self.ptr);
    }

    pub fn flush(self: Environment) !void {
        try switch (lmdb.mdb_env_sync(self.ptr, 0)) {
            0 => {},
            @enumToInt(std.os.E.INVAL) => error.INVAL,
            @enumToInt(std.os.E.ACCES) => error.ACCES,
            @enumToInt(std.os.E.IO) => error.IO,
            else => error.LmdbEnvironmentError,
        };
    }
};
