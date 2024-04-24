const std = @import("std");

const lmdb = @import("lmdb");

pub const Encoding = enum { raw, hex };

pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    const w = std.io.getStdErr().writer();
    std.fmt.format(w, "ERROR: ", .{}) catch unreachable;
    std.fmt.format(w, fmt, args) catch unreachable;
    std.fmt.format(w, "\n", .{}) catch unreachable;
    std.posix.exit(1);
}

var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;

pub fn open(dir: std.fs.Dir, options: lmdb.Environment.Options) !lmdb.Environment {
    const path = try dir.realpath(".", &path_buffer);
    path_buffer[path.len] = 0;
    return try lmdb.Environment.init(path_buffer[0..path.len :0], options);
}

pub fn openDB(allocator: std.mem.Allocator, txn: lmdb.Transaction, name: []const u8, options: lmdb.Database.Options) !lmdb.Database {
    if (name.len > 0) {
        const name_z = try allocator.allocSentinel(u8, name.len, 0);
        defer allocator.free(name_z);
        return try txn.database(name_z, options);
    } else {
        return txn.database(null, options);
    }
}
