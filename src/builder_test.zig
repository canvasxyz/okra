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

        const path = try lmdb.utils.resolvePath(tmp.dir, ".");
        const env = try lmdb.Environment.open(path, .{});
        defer env.close();

        const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadWrite });
        defer txn.abort();

        const db = try lmdb.Database.open(txn, .{ .create = true });

        var builder = try Builder.open(allocator, db, .{});
        defer builder.deinit();

        for (t.leaves) |leaf| try builder.set(leaf[0], leaf[1]);
        try builder.build();
        try lmdb.utils.expectEqualEntries(db, t.entries);
    }
}
