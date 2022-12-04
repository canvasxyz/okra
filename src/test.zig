const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Sha256 = std.crypto.hash.sha2.Sha256;

const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");

const Builder = @import("Builder.zig").Builder;
const SkipList = @import("SkipList.zig").SkipList;

const utils = @import("utils.zig");
const print = @import("print.zig");

fn testPermutations(
    comptime N: usize,
    comptime P: usize,
    comptime Q: usize,
    permutations: *const [N][P]u16,
    environment_options: lmdb.Environment.Options,
    skip_list_options: SkipList.Options,
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

        const reference_env = try lmdb.Environment.open(reference_path, environment_options);
        defer reference_env.close();

        {
            var builder = try Builder.open(allocator, reference_env, .{ .degree = skip_list_options.degree });
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

        const env = try lmdb.Environment.open(path, environment_options);
        defer env.close();

        var skip_list = try SkipList.open(allocator, env, skip_list_options);
        defer skip_list.deinit();

        {
            var txn = try lmdb.Transaction.open(env, .{ .read_only = false });
            errdefer txn.abort();

            var cursor = try lmdb.Cursor.open(txn);

            for (permutation) |i, j| {
                if (skip_list_options.log) |log|
                    try log.print("---------- {d} ({d} / {d}) ---------\n", .{ i, j, permutation.len });

                std.mem.writeIntBig(u16, &key, i);
                Sha256.hash(&key, &value, .{});
                try skip_list.set(txn, cursor, &key, &value);
            }

            for (permutations[(p + 1) % N][0..Q]) |i| {
                std.mem.writeIntBig(u16, &key, i);
                try skip_list.delete(txn, cursor, &key);
            }

            try txn.commit();
        }

        if (skip_list_options.log) |log| {
            try log.print("PERMUTATION -----\n{any}\n", .{permutation});
            try log.print("REFERENCE ENV --------------------------------------\n", .{});
            try print.printEntries(reference_env, log);
            try print.printTree(allocator, reference_env, log, .{});
            try log.print("SKIP LIST ENV --------------------------------------\n", .{});
            try print.printTree(allocator, skip_list.env, log, .{});
            try print.printEntries(env, log);
        }

        const delta = try lmdb.compareEntries(reference_env, env, .{ .log = skip_list_options.log });
        try expect(delta == 0);
    }
}

fn testPseudoRandomPermutations(
    comptime N: u16,
    comptime P: u16,
    comptime Q: u16,
    environment_options: lmdb.Environment.Options,
    skip_list_options: SkipList.Options,
) !void {
    var permutations: [N][P]u16 = undefined;

    var prng = std.rand.DefaultPrng.init(0x0000000000000000);
    var random = prng.random();

    var n: u16 = 0;
    while (n < N) : (n += 1) {
        var p: u16 = 0;
        while (p < P) : (p += 1) permutations[n][p] = p;
        std.rand.Random.shuffle(random, u16, &permutations[n]);
    }

    try testPermutations(N, P, Q, &permutations, environment_options, skip_list_options);
}

test "SkipList: 1 pseudo-random permutations of 10, deleting 0" {
    // const log = std.io.getStdErr().writer();
    // try log.print("\n", .{});
    const log = null;
    try testPseudoRandomPermutations(1, 10, 0, .{}, .{ .degree = 4, .log = log });
}

test "SkipList: 100 pseudo-random permutations of 50, deleting 0" {
    try testPseudoRandomPermutations(100, 50, 0, .{}, .{ .degree = 4 });
}

test "SkipList: 100 pseudo-random permutations of 500, deleting 50" {
    try testPseudoRandomPermutations(100, 500, 50, .{}, .{ .degree = 4 });
}

test "SkipList: 100 pseudo-random permutations of 1000, deleting 200" {
    try testPseudoRandomPermutations(100, 1000, 200, .{}, .{ .degree = 4 });
}

test "SkipList: 10 pseudo-random permutations of 10000, deleting 500" {
    try testPseudoRandomPermutations(10, 10000, 500, .{ .map_size = 2 * 1024 * 1024 * 1024 }, .{ .degree = 4 });
}

test "SkipList: 10 pseudo-random permutations of 50000, deleting 1000" {
    try testPseudoRandomPermutations(10, 10000, 1000, .{ .map_size = 2 * 1024 * 1024 * 1024 }, .{ .degree = 4 });
}
