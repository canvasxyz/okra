const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("./lmdb.zig");

const Options = struct {
  mapSize: usize = 10485760,
};

pub fn Environment(comptime K: usize, V: usize) type {
  return struct {
    pub const Error = error {
      LmdbVersionMismatch,
      LmdbEnvironmentError,
      LmdbCorruptDatabase,
      ACCES,
      NOENT,
      AGAIN,
    };

    ptr: ?*lmdb.MDB_env,

    pub fn open(path: [*:0]const u8, options: Options) !Environment(K, V) {
      var env = Environment(K, V){ .ptr = null };

      try switch (lmdb.mdb_env_create(&env.ptr)) {
        0 => {},
        else => Error.LmdbEnvironmentError,
      };

      try switch (lmdb.mdb_env_set_mapsize(env.ptr, options.mapSize)) {
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

    pub fn close(self: Environment(K, V)) void {
      lmdb.mdb_env_close(self.ptr);
    }
  };
}
