const std = @import("std");
const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");
const utils = @import("utils.zig");

const K = 16;
const Q = 32;
const Builder = @import("builder.zig").Builder(K, Q);
const Header = @import("header.zig").Header(K, Q);
const Tree = @import("tree.zig").Tree(K, Q);
const Transaction = @import("transaction.zig").Transaction(K, Q);
const Iterator = @import("iterator.zig").Iterator(K, Q);

fn printHeader(name: []const u8, log: std.fs.File.Writer) !void {
    try log.print("\n### {s}\n\n", .{name});
    try log.print(
        "| {s: <30} | {s: >10} | {s: >10} | {s: >10} | {s: >10} | {s: >10} | {s: >10} |\n",
        .{ "", "iterations", "min (ns)", "max (ns)", "avg (ns)", "std", "ops / s" },
    );
    try log.print(
        "| {s:-<30} | {s:->10} | {s:->10} | {s:->10} | {s:->10} | {s:->10} | {s:->10} |\n",
        .{ ":", ":", ":", ":", ":", ":", ":" },
    );
}

fn printRow(name: []const u8, runtimes: []const u64, operations: usize, log: std.fs.File.Writer) !void {
    var sum: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    for (runtimes) |t| {
        sum += t;
        if (t < min) min = t;
        if (t > max) max = t;
    }

    const avg = sum / runtimes.len;

    var sum_sq: u128 = 0;
    for (runtimes) |t| {
        const d = @as(i64, @intCast(@as(i128, @intCast(t)) - avg));
        sum_sq += @as(u64, @intCast(d * d));
    }

    const std_dev = std.math.sqrt(sum_sq / runtimes.len);
    const ops_per_second = (operations * 1_000_000_000) / avg;

    try log.print(
        "| {s: <30} | {d: >10} | {d: >10} | {d: >10} | {d: >10} | {d: >10} | {d: >10} |\n",
        .{ name, runtimes.len, min, max, avg, std_dev, ops_per_second },
    );
}

test "benchmark" {
    const log = std.io.getStdErr().writer();
    try log.print("\n", .{});

    try printHeader("Initial DB size: 1,000 entries", log);
    try runTests("read 1 random entry", 1_000, 1, ReadEntry(1_000).run, 100, log, false);
    try runTests("iterate over all entries", 1_000, 1_000, iterateOverEntries, 100, log, false);
    try runTests("set 1 random entry", 1_000, 1, SetEntries(1_000, 1).run, 100, log, true);
    try runTests("set 1,000 random entries", 1_000, 1_000, SetEntries(1_000, 1_000).run, 100, log, true);
    try runTests("set 50,000 random entries", 1_000, 50_000, SetEntries(1_000, 50_000).run, 10, log, true);

    try printHeader("Initial DB size: 50,000 entries", log);
    try runTests("read 1 random entry", 50_000, 1, ReadEntry(50_000).run, 100, log, false);
    try runTests("iterate over all entries", 50_000, 50_000, iterateOverEntries, 100, log, false);
    try runTests("set 1 random entry", 50_000, 1, SetEntries(50_000, 1).run, 100, log, true);
    try runTests("set 1,000 random entries", 50_000, 1_000, SetEntries(50_000, 1_000).run, 100, log, true);
    try runTests("set 50,000 random entries", 50_000, 50_000, SetEntries(50_000, 50_000).run, 10, log, true);

    try printHeader("Initial DB size: 1,000,000 entries", log);
    try runTests("read 1 random entry", 1_000_000, 1, ReadEntry(1_000_000).run, 100, log, false);
    try runTests("iterate over all entries", 1_000_000, 1_000_000, iterateOverEntries, 100, log, false);
    try runTests("set 1 random entry", 1_000_000, 1, SetEntries(1_000_000, 1).run, 100, log, true);
    try runTests("set 1,000 random entries", 1_000_000, 1000, SetEntries(1_000_000, 1_000).run, 100, log, true);
    try runTests("set 50,000 random entries", 1_000_000, 50_000, SetEntries(1_000_000, 50_000).run, 10, log, true);
}

var prng = std.rand.DefaultPrng.init(0x0000000000000000);
var random = prng.random();

fn ReadEntry(comptime size: u32) type {
    return struct {
        pub fn run(tree: *const Tree) !void {
            var txn = try Transaction.open(allocator, tree, .{ .mode = .ReadOnly });
            defer txn.abort();

            var seed: [4]u8 = undefined;
            var hash_buffer: [16]u8 = undefined;
            std.mem.writeIntBig(u32, &seed, random.uintLessThan(u32, size));
            std.crypto.hash.Blake3.hash(&seed, &hash_buffer, .{});
            if (try txn.get(hash_buffer[0..8])) |value| {
                std.debug.assert(std.mem.eql(u8, value, hash_buffer[8..16]));
            }
        }
    };
}

fn iterateOverEntries(tree: *const Tree) !void {
    var txn = try Transaction.open(allocator, tree, .{ .mode = .ReadOnly });
    defer txn.abort();

    const range = Iterator.Range{
        .level = 0,
        .lower_bound = .{ .key = null, .inclusive = false },
    };

    var iterator = try Iterator.open(allocator, &txn, range);
    defer iterator.close();

    while (try iterator.next()) |leaf| {
        std.debug.assert(leaf.key.?.len == 8);
        std.debug.assert(leaf.value.?.len == 8);
    }
}

fn SetEntries(comptime initial_size: u32, comptime count: u32) type {
    return struct {
        pub fn run(tree: *const Tree) !void {
            var txn = try Transaction.open(allocator, tree, .{ .mode = .ReadWrite });
            errdefer txn.abort();

            var i: u32 = initial_size;
            var seed: [4]u8 = undefined;
            var hash_buffer: [16]u8 = undefined;
            while (i < initial_size + count) : (i += 1) {
                std.mem.writeIntBig(u32, &seed, i);
                std.crypto.hash.Blake3.hash(&seed, &hash_buffer, .{});
                try txn.set(hash_buffer[0..8], hash_buffer[8..16]);
            }

            try txn.commit();
            try tree.env.flush();
        }
    };
}

fn runTests(
    comptime name: []const u8,
    comptime initial_entries: usize,
    comptime operations: usize,
    comptime run: fn (tree: *const Tree) anyerror!void,
    comptime iterations: usize,
    log: std.fs.File.Writer,
    reset: bool,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("mst");
    const path = try utils.resolvePath(tmp.dir, "mst");

    var tree = try initialize(initial_entries, path);

    var runtimes: [iterations]u64 = undefined;
    var timer = try std.time.Timer.start();
    for (runtimes) |*t| {
        timer.reset();
        try run(&tree);
        t.* = timer.read();

        if (reset) {
            tree.close();
            try tmp.dir.deleteTree("mst");
            try tmp.dir.makeDir("mst");
            tree = try initialize(initial_entries, path);
        }
    }

    tree.close();

    try printRow(name, &runtimes, operations, log);
}

fn initialize(comptime initial_entries: usize, path: [*:0]const u8) !Tree {
    var tree = try Tree.open(allocator, path, .{ .map_size = 2 * 1024 * 1024 * 1024 });

    if (initial_entries > 0) {
        var builder = try Builder.open(allocator, tree.env, .{});
        errdefer builder.abort();

        var i: u32 = 0;
        var seed: [4]u8 = undefined;
        var hash_buffer: [16]u8 = undefined;
        while (i < initial_entries) : (i += 1) {
            std.mem.writeIntBig(u32, &seed, i);
            std.crypto.hash.Blake3.hash(&seed, &hash_buffer, .{});
            try builder.set(hash_buffer[0..8], hash_buffer[8..16]);
        }

        try builder.commit();
    }

    try tree.env.flush();
    return tree;
}
