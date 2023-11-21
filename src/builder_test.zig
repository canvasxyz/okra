const std = @import("std");
const lmdb = @import("lmdb");

const K = 32;
const Q = 4;
const Builder = @import("builder.zig").Builder(K, Q);

const library = @import("library.zig");
const allocator = std.heap.c_allocator;

test "Builder" {
    for (&library.tests) |t| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const env = try lmdb.Environment.openDir(tmp.dir, .{ .max_dbs = 1 });
        defer env.close();

        const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadWrite });
        defer txn.abort();

        const dbi = try txn.openDatabase(null, .{});

        var builder = try Builder.open(allocator, txn, dbi, .{});
        defer builder.deinit();

        for (t.leaves) |leaf| try builder.set(leaf[0], leaf[1]);
        try builder.build();
        try lmdb.utils.expectEqualEntries(txn, dbi, t.entries);
    }
}
