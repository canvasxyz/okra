const std = @import("std");
const assert = std.debug.assert;

const Environment = @import("./lmdb/environment.zig").Environment;
const EnvironmentOptions = @import("./lmdb/environment.zig").EnvironmentOptions;
const Transaction = @import("./lmdb/transaction.zig").Transaction;
const Cursor = @import("./lmdb/cursor.zig").Cursor;

const Key = @import("./key.zig").Key;

const utils = @import("./utils.zig");

const allocator = std.heap.c_allocator;

pub fn printEntries(comptime X: u32, path: []const u8, writer: std.fs.File.Writer, options: EnvironmentOptions) !void {
    var env = try Environment.open(path, options);
    var txn = try Transaction.open(env, true);
    var dbi = try txn.openDbi();

    var cursor = try Cursor.open(txn, dbi);

    var cursorKey = try cursor.goToFirst();
    while (cursorKey) |bytes| : (cursorKey = try cursor.goToNext()) {
        assert(bytes.len == Key(X).SIZE);
        const key = @ptrCast(*const Key(X), bytes.ptr);
        if (cursor.getCurrentValue()) |value| {
            assert(value.len == 32);
            try writer.print("{s} -> {s}\n", .{ try key.toString(), utils.printHash(value) });
        } else {
            @panic("internal error: no value found for key");
        }
    }

    cursor.close();
    txn.abort();
    env.close();
}