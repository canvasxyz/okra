const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("lmdb");

const Tree = @import("tree.zig").Tree;
const Header = @import("header.zig").Header;
const Builder = @import("builder.zig").Builder;
const Transaction = @import("transaction.zig").Transaction;

const utils = @import("utils.zig");
const print = @import("print.zig");

fn testPermutations(
    comptime Q: u8,
    comptime K: u8,
    comptime N: usize,
    comptime P: usize,
    comptime R: usize,
    permutations: *const [N][P]u16,
    log: ?std.fs.File.Writer,
    environment_options: lmdb.Environment.Options,
) !void {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try expect(R < P);

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
            var builder = try Builder(Q, K).open(allocator, reference_env, .{});
            errdefer builder.abort();

            for (permutation) |i| {
                std.mem.writeIntBig(u16, &key, i);
                Sha256.hash(&key, &value, .{});
                try builder.set(&key, &value);
            }

            for (permutations[(p + 1) % N][0..R]) |i| {
                std.mem.writeIntBig(u16, &key, i);
                try builder.delete(&key);
            }

            try builder.commit();
        }

        const name = try std.fmt.bufPrint(&name_buffer, "p{d}.{x}.mdb", .{ N, p });
        const path = try utils.resolvePath(allocator, tmp.dir, name);
        defer allocator.free(path);

        const tree = try Tree(4, 32).open(allocator, path, .{});
        defer tree.close();

        {
            const txn = try Transaction(Q, K).open(allocator, tree, .{ .read_only = false, .log = log });
            errdefer txn.abort();

            for (permutation) |i, j| {
                if (log) |writer|
                    try writer.print("---------- {d} ({d} / {d}) ---------\n", .{ i, j, permutation.len });

                std.mem.writeIntBig(u16, &key, i);
                Sha256.hash(&key, &value, .{});
                try txn.set(&key, &value);
            }

            for (permutations[(p + 1) % N][0..R]) |i| {
                std.mem.writeIntBig(u16, &key, i);
                try txn.delete(&key);
            }

            try txn.commit();
        }

        if (log) |writer| {
            try writer.print("PERMUTATION -----\n{any}\n", .{permutation});
            try writer.print("EXPECTED -----------------------------------------\n", .{});
            try print.printEntries(reference_env, writer);
            // try print.printTree(allocator, reference_env, writer, .{});
            try writer.print("ACTUAL -------------------------------------------\n", .{});
            // try print.printTree(allocator, env, writer, .{});
            try print.printEntries(tree.env, writer);
        }

        const delta = try lmdb.compareEntries(reference_env, tree.env, .{ .log = log });
        try expect(delta == 0);
    }
}

fn testPseudoRandomPermutations(
    comptime Q: u8,
    comptime K: u8,
    comptime N: u16,
    comptime P: u16,
    comptime R: u16,
    log: ?std.fs.File.Writer,
    environment_options: lmdb.Environment.Options,
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

    try testPermutations(Q, K, N, P, R, &permutations, log, environment_options);
}

test "1 pseudo-random permutations of 10, deleting 0" {
    // const log = std.io.getStdErr().writer();
    // try log.print("\n", .{});
    try testPseudoRandomPermutations(4, 32, 1, 10, 0, null, .{});
}

test "100 pseudo-random permutations of 50, deleting 0" {
    try testPseudoRandomPermutations(4, 32, 100, 50, 0, null, .{});
}

test "100 pseudo-random permutations of 500, deleting 50" {
    try testPseudoRandomPermutations(4, 32, 100, 500, 50, null, .{});
}

test "100 pseudo-random permutations of 1000, deleting 200" {
    try testPseudoRandomPermutations(4, 32, 100, 1000, 200, null, .{});
}

test "10 pseudo-random permutations of 10000, deleting 500" {
    try testPseudoRandomPermutations(4, 32, 10, 10000, 500, null, .{ .map_size = 2 * 1024 * 1024 * 1024 });
}

test "10 pseudo-random permutations of 50000, deleting 1000" {
    try testPseudoRandomPermutations(4, 32, 10, 10000, 1000, null, .{ .map_size = 2 * 1024 * 1024 * 1024 });
}
