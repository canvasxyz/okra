const std = @import("std");
const lmdb = @import("lmdb");

pub const Error = error{ Uninitialized, InvalidDatabase, NotFound } ||
    lmdb.Error ||
    std.fs.File.WriteError ||
    std.mem.Allocator.Error;
