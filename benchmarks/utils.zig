const std = @import("std");

const lmdb = @import("lmdb");

var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;

pub fn open(dir: std.fs.Dir, options: lmdb.Environment.Options) !lmdb.Environment {
    const path = try dir.realpath(".", &path_buffer);
    path_buffer[path.len] = 0;
    return try lmdb.Environment.init(path_buffer[0..path.len :0], options);
}
