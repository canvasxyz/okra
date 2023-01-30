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

        // const log = std.io.getStdErr().writer();
        // try log.print("\n", .{});

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
        defer allocator.free(path);

        const env = try lmdb.Environment.open(path, .{});
        defer env.close();

        var builder = try Builder.open(allocator, env, .{});

        for (t.leaves) |leaf| try builder.set(leaf[0], leaf[1]);

        try builder.commit();

        // try log.print("----------------------------------------------------------------\n", .{});
        // try print.printEntries(env, log);

        try lmdb.expectEqualEntries(env, t.entries);

        // try log.print("----------------------------------------------------------------\n", .{});
        // try printTree(allocator, env, log, .{ .compact = true });

    }
}
