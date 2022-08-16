const std = @import("std");

const lmdb = @import("./lmdb.zig").lmdb;

pub const EnvironmentOptions = struct {
  mapSize: usize = 10485760,
};

pub const Environment = struct {
  pub const Error = error {
    LmdbVersionMismatch,
    LmdbEnvironmentError,
    LmdbCorruptDatabase,
    ACCES,
    NOENT,
    AGAIN,
  };

  ptr: ?*lmdb.MDB_env,

  pub fn open(path: []const u8, options: EnvironmentOptions) !Environment {
    var env = Environment { .ptr = null };

    try switch (lmdb.mdb_env_create(&env.ptr)) {
      0 => {},
      else => Error.LmdbEnvironmentError,
    };

    try switch (lmdb.mdb_env_set_mapsize(env.ptr, options.mapSize)) {
      0 => {},
      else => Error.LmdbEnvironmentError,
    };

    const cPath = getCString(path);

    const flags = lmdb.MDB_WRITEMAP | lmdb.MDB_NOSUBDIR;
    const mode = 0o664;

    errdefer lmdb.mdb_env_close(env.ptr);
    try switch (lmdb.mdb_env_open(env.ptr, cPath, flags, mode)) {
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


var pathBuffer = [_]u8 { 0 } ** 4096;

fn getCString(value: []const u8) [:0]u8 {
  std.mem.copy(u8, &pathBuffer, value);
  pathBuffer[value.len] = 0;
  return pathBuffer[0..value.len :0];
}