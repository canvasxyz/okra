const std = @import("std");
const lmdb = @import("lmdb");

const K = 32;
const Q = 4;
const Builder = @import("builder.zig").Builder(K, Q);

const utils = @import("utils.zig");
const library = @import("library.zig");

test "Builder" {
    for (&library.tests) |t| {
        const allocator = std.heap.c_allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const path = try utils.resolvePath(tmp.dir, ".");
        const env = try lmdb.Environment.open(path, .{});
        defer env.close();

        var builder = try Builder.open(allocator, env, .{});

        for (t.leaves) |leaf| try builder.set(leaf[0], leaf[1]);

        try builder.commit();

        try lmdb.expectEqualEntries(env, t.entries);
    }
}
