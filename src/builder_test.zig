const std = @import("std");
const lmdb = @import("lmdb");

const K = 32;
const Q = 4;
const Builder = @import("builder.zig").Builder(K, Q);

const utils = @import("utils.zig");
const library = @import("library.zig");

test "Builder" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    for (&library.tests) |t| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const env = try utils.open(tmp.dir, .{});
        defer env.deinit();

        const txn = try env.transaction(.{ .mode = .ReadWrite });
        defer txn.abort();

        const db = try txn.database(null, .{});

        var builder = try Builder.init(allocator, db, .{});
        defer builder.deinit();

        for (t.leaves) |leaf| try builder.set(leaf[0], leaf[1]);
        try builder.build();
        try utils.expectEqualEntries(db, t.entries);
    }
}
