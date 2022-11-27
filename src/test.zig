const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Sha256 = std.crypto.hash.sha2.Sha256;

const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");

const Builder = @import("Builder.zig").Builder;
const SkipList = @import("SkipList.zig").SkipList;
const SkipListCursor = @import("SkipListCursor.zig").SkipListCursor;

const utils = @import("utils.zig");
const print = @import("print.zig");

fn testPermutations(
    comptime N: usize,
    comptime P: usize,
    comptime Q: usize,
    permutations: *const [N][P]u16,
    options: SkipList.Options,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try expect(Q < P);

    var key: [2]u8 = undefined;
    var value: [32]u8 = undefined;

    var name_buffer: [24]u8 = undefined;
    for (permutations) |permutation, p| {
        const reference_name = try std.fmt.bufPrint(&name_buffer, "r{d}.{x}.mdb", .{ N, p });
        const reference_path = try utils.resolvePath(allocator, tmp.dir, reference_name);
        defer allocator.free(reference_path);

        const reference_env = try lmdb.Environment.open(reference_path, .{ .map_size = options.map_size });
        defer reference_env.close();

        {
            var builder = try Builder.init(reference_env, .{ .degree = options.degree });
            errdefer builder.abort();

            for (permutation) |i| {
                std.mem.writeIntBig(u16, &key, i);
                Sha256.hash(&key, &value, .{});
                try builder.set(&key, &value);
            }

            for (permutations[(p + 1) % N][0..Q]) |i| {
                std.mem.writeIntBig(u16, &key, i);
                try builder.delete(&key);
            }

            try builder.commit();
        }

        const name = try std.fmt.bufPrint(&name_buffer, "p{d}.{x}.mdb", .{ N, p });
        const path = try utils.resolvePath(allocator, tmp.dir, name);
        defer allocator.free(path);

        var skip_list = try SkipList.open(allocator, path, options);
        defer skip_list.close();

        {
            var skip_list_cursor = try SkipListCursor.open(allocator, skip_list.env, false);
            errdefer skip_list_cursor.abort();

            for (permutation) |i, j| {
                if (options.log) |log|
                    try log.print("---------- {d} ({d} / {d}) ---------\n", .{ i, j, permutation.len });

                std.mem.writeIntBig(u16, &key, i);
                Sha256.hash(&key, &value, .{});
                try skip_list.set(&skip_list_cursor, &key, &value);
            }

            for (permutations[(p + 1) % N][0..Q]) |i| {
                std.mem.writeIntBig(u16, &key, i);
                try skip_list.delete(&skip_list_cursor, &key);
            }

            try skip_list_cursor.commit();
        }

        if (options.log) |log| {
            try log.print("PERMUTATION -----\n{any}\n", .{permutation});
            try log.print("REFERENCE ENV --------------------------------------\n", .{});
            try print.printEntries(reference_env, log);
            try print.printTree(allocator, reference_env, log, .{});
            try log.print("SKIP LIST ENV --------------------------------------\n", .{});
            try print.printTree(allocator, skip_list.env, log, .{});
            // try print.printEntries(skip_list.env, log);
        }

        const delta = try lmdb.compareEntries(reference_env, skip_list.env, .{ .log = options.log });
        try expect(delta == 0);
    }
}

fn testPseudoRandomPermutations(comptime N: u16, comptime P: u16, comptime Q: u16, options: SkipList.Options) !void {
    var permutations: [N][P]u16 = undefined;

    var prng = std.rand.DefaultPrng.init(0x0000000000000000);
    var random = prng.random();

    var n: u16 = 0;
    while (n < N) : (n += 1) {
        var p: u16 = 0;
        while (p < P) : (p += 1) permutations[n][p] = p;
        std.rand.Random.shuffle(random, u16, &permutations[n]);
    }

    try testPermutations(N, P, Q, &permutations, options);
}

test "SkipList: 100 pseudo-random permutations of 50, deleting 0" {
    try testPseudoRandomPermutations(100, 50, 0, .{ .degree = 4 });
}

test "SkipList: 100 pseudo-random permutations of 500, deleting 50" {
    try testPseudoRandomPermutations(100, 500, 50, .{ .degree = 4 });
}

test "SkipList: 100 pseudo-random permutations of 1000, deleting 200" {
    try testPseudoRandomPermutations(100, 1000, 200, .{ .degree = 4 });
}

test "SkipList: 10 pseudo-random permutations of 10000, deleting 500" {
    try testPseudoRandomPermutations(10, 10000, 500, .{ .map_size = 2 * 1024 * 1024 * 1024, .degree = 4 });
}

test "SkipList: 10 pseudo-random permutations of 50000, deleting 1000" {
    try testPseudoRandomPermutations(10, 10000, 1000, .{ .map_size = 2 * 1024 * 1024 * 1024, .degree = 4 });
}
