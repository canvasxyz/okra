const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Sha256 = std.crypto.hash.sha2.Sha256;

const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");

const Builder = @import("./Builder.zig").Builder;
const SkipList = @import("./SkipList.zig").SkipList;
const SkipListCursor = @import("./SkipListCursor.zig").SkipListCursor;

const utils = @import("./utils.zig");

fn testPermutations(comptime N: usize, permutations: []const [N]u16, options: SkipList.Options) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var key: [2]u8 = undefined;
    var value: [32]u8 = undefined;

    const reference_path = try utils.resolvePath(allocator, tmp.dir, "reference.mdb");
    defer allocator.free(reference_path);

    const reference_env = try lmdb.Environment.open(reference_path, .{ .map_size = options.map_size });
    defer reference_env.close();

    {
        var builder = try Builder.init(reference_env, .{ .degree = options.degree });
        errdefer builder.abort();

        for (permutations[0]) |i| {
            std.mem.writeIntBig(u16, &key, i);
            Sha256.hash(&key, &value, .{});
            try builder.set(&key, &value);
        }

        try builder.commit();
    }

    var name_buffer: [24]u8 = undefined;
    for (permutations) |permutation, p| {
        const name = try std.fmt.bufPrint(&name_buffer, "p{d}.{x}.mdb", .{ N, p });
        const path = try utils.resolvePath(allocator, tmp.dir, name);
        defer allocator.free(path);

        var skip_list = try SkipList.open(allocator, path, options);
        defer skip_list.close();

        {
            var skip_list_cursor = try SkipListCursor.open(allocator, skip_list.env, false);
            errdefer skip_list_cursor.abort();

            for (permutation) |i| {
                std.mem.writeIntBig(u16, &key, i);
                Sha256.hash(&key, &value, .{});
                try skip_list.insert(&skip_list_cursor, &key, &value);
            }

            try skip_list_cursor.commit();
        }

        const delta = try lmdb.compareEntries(reference_env, skip_list.env, .{ .log = options.log });
        try expect(delta == 0);
    }
}

test "SkipList: static permutations of 10" {
    const permutations = [_][10]u16{
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        .{ 4, 6, 7, 2, 5, 1, 8, 3, 9, 0 },
        .{ 5, 0, 8, 2, 9, 3, 4, 7, 6, 1 },
        .{ 4, 5, 8, 2, 0, 1, 6, 7, 9, 3 },
        .{ 1, 7, 6, 5, 8, 3, 4, 2, 0, 9 },
    };

    try testPermutations(10, &permutations, .{ .degree = 4 });
}

test "SkipList: static permutations of 100" {
    const permutations = [_][100]u16{
        .{
            0, 74, 33, 97, 25, 91, 77, 29, 83, 1, 24, 86, 35, 11, 7, 48, 60, 21, 96, 68, 59, 12, 78, 17, 98, 43, 46, 76, 9, 73,
            85, 20, 18, 36, 82, 71, 69, 40, 92, 57, 84, 37, 45, 75, 39, 88, 87, 5, 90, 22, 2, 23, 38, 47, 65, 93, 67, 56, 30,
            34, 41, 10, 62, 8, 44, 14, 26, 51, 52, 13, 19, 53, 61, 95, 66, 64, 94, 49, 4, 55, 6, 50, 54, 79, 89, 42, 80, 27, 16,
            81, 15, 99, 70, 3, 72, 63, 28, 31, 58, 32
        },
        .{
            37, 86, 2, 59, 96, 46, 0, 18, 26, 99, 97, 61, 87, 24, 53, 28, 17, 82, 73, 41, 29, 83, 76, 74, 51, 45, 32, 30, 95,
            52, 1, 57, 39, 48, 58, 70, 89, 16, 31, 77, 60, 34, 5, 33, 54, 21, 38, 3, 40, 10, 42, 44, 75, 72, 19, 22, 15, 9, 36,
            98, 69, 55, 64, 27, 93, 49, 66, 81, 78, 11, 65, 13, 23, 68, 7, 35, 80, 47, 91, 25, 20, 71, 63, 43, 4, 94, 67, 90,
            56, 88, 79, 84, 50, 62, 14, 12, 6, 92, 85, 8
        },
        .{
            19, 55, 99, 65, 4, 71, 82, 66, 23, 68, 97, 20, 41, 63, 50, 46, 6, 31, 49, 45, 80, 58, 77, 95, 70, 60, 59, 34, 16,
            22, 7, 94, 87, 15, 72, 42, 12, 17, 1, 64, 11, 28, 69, 89, 36, 98, 18, 21, 3, 74, 0, 75, 2, 39, 62, 44, 40, 43, 79,
            84, 57, 47, 32, 30, 5, 67, 93, 27, 85, 96, 56, 13, 10, 92, 54, 37, 33, 73, 91, 38, 88, 48, 76, 35, 81, 29, 26, 90,
            51, 78, 14, 9, 52, 8, 25, 83, 24, 61, 53, 86
        },
        .{
            88, 23, 26, 0, 56, 16, 53, 15, 81, 27, 45, 77, 44, 12, 43, 59, 3, 96, 61, 29, 65, 47, 40, 70, 64, 19, 36, 84, 69,
            83, 66, 74, 86, 48, 71, 14, 25, 49, 28, 41, 38, 13, 21, 10, 1, 57, 95, 52, 80, 34, 79, 50, 32, 4, 33, 72, 7, 75, 62,
            31, 35, 17, 89, 51, 91, 93, 5, 97, 46, 18, 68, 37, 55, 22, 6, 76, 87, 98, 58, 20, 9, 42, 94, 85, 63, 39, 78, 82, 60,
            90, 11, 24, 99, 30, 8, 54, 2, 67, 73, 92
        },
    };

    try testPermutations(100, &permutations, .{ .degree = 4 });
}

fn testPseudoRandomPermutations(comptime N: u16, comptime P: u16, options: SkipList.Options) !void {
    var permutations: [N][P]u16 = undefined;
    var i: u16 = 0;
    while (i < P) : (i += 1) {
        var j: u16 = 0;
        while (j < N) : (j += 1) {
            permutations[j][i] = i;
        }
    }

    var prng = std.rand.DefaultPrng.init(0x0000000000000000);
    var random = prng.random();
    var j: u16 = 0;
    while (j < N) : (j += 1)
        std.rand.Random.shuffle(random, u16, &permutations[j]);

    try testPermutations(P, &permutations, options);
}

test "SkipList: 100 pseudo-random permutations of 1000" {
    // const log = std.io.getStdErr().writer();
    // try log.print("\n", .{});
    try testPseudoRandomPermutations(10, 10000, .{ .degree = 4 });
}

test "SkipList: 10 pseudo-random permutations of 10000" {
    try testPseudoRandomPermutations(10, 10000, .{ .map_size = 2 * 1024 * 1024 * 1024, .degree = 4 });
}

test "SkipList: 10 pseudo-random permutations of 50000" {
    try testPseudoRandomPermutations(10, 10000, .{ .map_size = 2 * 1024 * 1024 * 1024, .degree = 4 });
}
