const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb.zig");

pub const Environment = struct {
    pub const Options = struct {
        map_size: usize = 10485760,
        create: bool = true,
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
            else => Error.LmdbEnvironmentError,
        };

        try switch (lmdb.mdb_env_set_mapsize(env.ptr, options.map_size)) {
            0 => {},
            else => Error.LmdbEnvironmentError,
        };

        const flags = lmdb.MDB_WRITEMAP | lmdb.MDB_NOSUBDIR | lmdb.MDB_NOLOCK;
        const mode = 0o664;

        errdefer lmdb.mdb_env_close(env.ptr);
        try switch (lmdb.mdb_env_open(env.ptr, path, flags, mode)) {
            0 => {},
            lmdb.MDB_VERSION_MISMATCH => Error.LmdbVersionMismatch,
            lmdb.MDB_INVALID => Error.LmdbCorruptDatabase,
            @enumToInt(std.os.E.ACCES) => Error.ACCES,
            @enumToInt(std.os.E.NOENT) => Error.NOENT,
            @enumToInt(std.os.E.AGAIN) => Error.AGAIN,
            else => Error.LmdbEnvironmentError,
        };

        return env;
    }

    pub fn close(self: Environment) void {
        lmdb.mdb_env_close(self.ptr);
    }
};
