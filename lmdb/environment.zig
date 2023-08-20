const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb.zig");

pub const Environment = struct {
    pub const Options = struct {
        map_size: usize = 10485760,
        max_dbs: u32 = 0,
        mode: u16 = 0o664,
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
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbEnvironmentError,
        };

        try switch (lmdb.mdb_env_set_maxdbs(env.ptr, options.max_dbs)) {
            0 => {},
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            else => error.LmdbEnvironmentError,
        };

        const flags: u32 = lmdb.MDB_NOTLS;

        errdefer lmdb.mdb_env_close(env.ptr);
        try switch (lmdb.mdb_env_open(env.ptr, path, flags, options.mode)) {
            0 => {},
            lmdb.MDB_VERSION_MISMATCH => error.LmdbEnvironmentVersionMismatch,
            lmdb.MDB_INVALID => error.LmdbCorruptDatabase,
            @intFromEnum(std.os.E.ACCES) => error.ACCES,
            @intFromEnum(std.os.E.NOENT) => error.NOENT,
            @intFromEnum(std.os.E.AGAIN) => error.AGAIN,
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
            @intFromEnum(std.os.E.INVAL) => error.INVAL,
            @intFromEnum(std.os.E.ACCES) => error.ACCES,
            @intFromEnum(std.os.E.IO) => error.IO,
            else => error.LmdbEnvironmentError,
        };
    }

    pub const Stat = struct { entries: usize };

    pub fn stat(self: Environment) !Stat {
        var result: lmdb.MDB_stat = undefined;
        try switch (lmdb.mdb_env_stat(self.ptr, &result)) {
            0 => {},
            else => error.LmdbEnvironmentError,
        };

        return .{ .entries = result.ms_entries };
    }
};
