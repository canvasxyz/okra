const std = @import("std");
const allocator = std.heap.c_allocator;

const Environment = @import("environment.zig").Environment;
const Transaction = @import("transaction.zig").Transaction;
const Cursor = @import("cursor.zig").Cursor;
const utils = @import("./utils.zig");

fn printHeader(name: []const u8, log: std.fs.File.Writer) !void {
    try log.print("\n### {s}\n\n", .{name});
    try log.print(
        "| {s: <30} | {s: >10} | {s: >8} | {s: >8} | {s: >8} | {s: >8} | {s: >10} |\n",
        .{ "", "iterations", "min (ns)", "max (ns)", "avg (ns)", "std", "ops / s" },
    );
    try log.print(
        "| {s:-<30} | {s:->10} | {s:->8} | {s:->8} | {s:->8} | {s:->8} | {s:->10} |\n",
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
        const d = @intCast(i64, @intCast(i128, t) - avg);
        sum_sq += @intCast(u64, d * d);
    }

    const std_dev = std.math.sqrt(sum_sq / runtimes.len);
    const ops_per_second = (operations * 1_000_000_000) / avg;

    try log.print(
        "| {s: <30} | {d: >10} | {d: >8} | {d: >8} | {d: >8} | {d: >8} | {d: >10} |\n",
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
            var txn = try Transaction.open(tree, .{ .read_only = true });
            defer txn.abort();

            var i_buffer: [4]u8 = undefined;
            var hash_buffer: [32]u8 = undefined;
            std.mem.writeIntBig(u32, &i_buffer, random.uintLessThan(u32, size));
            std.crypto.hash.Blake3.hash(&i_buffer, &hash_buffer, .{});
            if (try txn.get(hash_buffer[0..16])) |value| {
                std.debug.assert(std.mem.eql(u8, value, hash_buffer[16..32]));
            }
        }
    };
}

fn iterateOverEntries(env: Environment) !void {
    const txn = try Transaction.open(env, .{ .read_only = true });
    defer txn.abort();

    const cursor = try Cursor.open(txn);
    defer cursor.close();

    if (try cursor.goToFirst()) |first_key| {
        std.debug.assert(first_key.len == 16);
        while (try cursor.goToNext()) |key| {
            std.debug.assert(key.len == 16);
        }
    }
}

fn SetEntries(comptime initial_size: u32, comptime count: u32) type {
    return struct {
        pub fn run(tree: *const Tree) !void {
            var txn = try Transaction.open(tree, .{ .read_only = false });
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
    comptime run: fn (env: Environment) anyerror!void,
    comptime iterations: usize,
    log: std.fs.File.Writer,
    reset: bool,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("mst");
    const path = try utils.resolvePath(tmp.dir, "mst");

    var tree = try Tree.open(path, .{ .map_size = 2 * 1024 * 1024 * 1024 });
    defer tree.close();
    try initialize(initial_entries, &tree);

    var runtimes: [iterations]u64 = undefined;
    var timer = try std.time.Timer.start();
    for (runtimes) |*t| {
        timer.reset();
        try run(env);
        t.* = timer.read();

        if (reset) {
            env.close();
            try tmp.dir.deleteTree("mst");
            try tmp.dir.makeDir("mst");
            env = try initialize(initial_entries, path);
        }
    }

    try printRow(name, &runtimes, operations, log);
}

fn initialize(comptime initial_entries: usize, tree: *const Tree) !void {
    if (initial_entries > 0) {
        const txn = try Transaction.open(tree, .{ .read_only = false });
        errdefer txn.abort();

        var i: u32 = 0;
        var seed: [4]u8 = undefined;
        var hash_buffer: [16]u8 = undefined;
        while (i < initial_entries) : (i += 1) {
            std.mem.writeIntBig(u32, &seed, i);
            std.crypto.hash.Blake3.hash(&seed, &hash_buffer, .{});
            try txn.set(hash_buffer[0..8], hash_buffer[8..16]);
        }

        try txn.commit();
    }

    try tree.env.flush();
}
