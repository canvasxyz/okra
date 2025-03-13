const std = @import("std");
const lmdb = @import("lmdb");

pub const Error = error{ Uninitialized, InvalidDatabase, InvalidVersion, InvalidMetadata, NotFound, Invalid } ||
    lmdb.Error ||
    std.fs.File.WriteError ||
    std.mem.Allocator.Error;
