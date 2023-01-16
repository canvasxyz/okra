const std = @import("std");
const allocator = std.heap.c_allocator;

const Environment = @import("environment.zig").Environment;
const Transaction = @import("transaction.zig").Transaction;
const Cursor = @import("cursor.zig").Cursor;

fn printHeader(name: []const u8, log: std.fs.File.Writer) !void {
    try log.print("\n", .{});
    try log.print(
        "| {s: <40} | {s: >10} | {s: >8} | {s: >8} | {s: >8} | {s: >8} | {s: >10} |\n",
        .{ name, "iterations", "min (ns)", "max (ns)", "avg (ns)", "std", "ops / s" },
    );
    try log.print(
        "| {s:-<40} | {s:->10} | {s:->8} | {s:->8} | {s:->8} | {s:->8} | {s:->10} |\n",
        .{ "", "", "", "", "", "", "" },
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
        "| {s: <40} | {d: >10} | {d: >8} | {d: >8} | {d: >8} | {d: >8} | {d: >10} |\n",
        .{ name, runtimes.len, min, max, avg, std_dev, ops_per_second },
    );
}

test "benchmark reads" {
    const log = std.io.getStdErr().writer();
    try log.print("\n", .{});

    try printHeader("**INITIAL DB SIZE: 1,000 ENTRIES**", log);
    try runTests("- read 1 random entry", 1000, 1, ReadEntry(1000).run, 100, log, false);
    try runTests("- iterate over all entries", 1000, 1000, iterateOverEntries, 100, log, false);

    try printHeader("**INITIAL DB SIZE: 100,000 ENTRIES**", log);
    try runTests("- read 1 random entry", 100000, 1, ReadEntry(100000).run, 100, log, false);
    try runTests("- iterate over all entries", 100000, 100000, iterateOverEntries, 100, log, false);
}

test "benchmark writes" {
    const log = std.io.getStdErr().writer();

    try printHeader("**INITIAL DB SIZE: 0 ENTRIES**", log);
    try runTests("- set 1 random entry", 0, 1, SetEntries(0, 1).run, 100, log, true);
    try runTests("- set 1,000 random entries", 0, 1000, SetEntries(0, 1000).run, 100, log, true);
    try runTests("- set 100,000 random entries", 0, 100000, SetEntries(0, 100000).run, 10, log, true);

    try printHeader("**INITIAL DB SIZE: 1,000 ENTRIES**", log);
    try runTests("- set 1 random entry", 1000, 1, SetEntries(1000, 1).run, 100, log, true);
    try runTests("- set 1,000 random entries", 1000, 1000, SetEntries(1000, 1000).run, 100, log, true);
    try runTests("- set 100,000 random entries", 1000, 100000, SetEntries(1000, 100000).run, 10, log, true);

    try printHeader("**INITIAL DB SIZE: 100,000 ENTRIES**", log);
    try runTests("- set 1 random entry", 100000, 1, SetEntries(100000, 1).run, 100, log, true);
    try runTests("- set 1,000 random entries", 100000, 1000, SetEntries(100000, 1000).run, 100, log, true);
    try runTests("- set 100,000 random entries", 100000, 100000, SetEntries(100000, 100000).run, 10, log, true);
}

var prng = std.rand.DefaultPrng.init(0x0000000000000000);
var random = prng.random();

fn ReadEntry(comptime size: u32) type {
    return struct {
        pub fn run(env: Environment) !void {
            const txn = try Transaction.open(env, .{ .read_only = true });
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
        pub fn run(env: Environment) !void {
            const txn = try Transaction.open(env, .{ .read_only = false });
            errdefer txn.abort();

            var i: u32 = initial_size;
            var i_buffer: [4]u8 = undefined;
            var hash_buffer: [32]u8 = undefined;
            while (i < initial_size + count) : (i += 1) {
                std.mem.writeIntBig(u32, &i_buffer, i);
                std.crypto.hash.Blake3.hash(&i_buffer, &hash_buffer, .{});
                try txn.set(hash_buffer[0..16], hash_buffer[16..32]);
            }

            try txn.commit();
            try env.flush();
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

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const path = try std.fs.path.joinZ(allocator, &.{ tmp_path, "data.mdb" });
    defer allocator.free(path);

    var env = try initialize(initial_entries, path);

    var runtimes: [iterations]u64 = undefined;
    var timer = try std.time.Timer.start();
    for (runtimes) |*t| {
        timer.reset();
        try run(env);
        t.* = timer.read();

        if (reset) {
            env.close();
            try std.fs.deleteFileAbsoluteZ(path);
            env = try initialize(initial_entries, path);
        }
    }

    env.close();

    try printRow(name, &runtimes, operations, log);
}

fn initialize(comptime initial_entries: usize, path: [*:0]const u8) !Environment {
    const env = try Environment.open(path, .{ .map_size = 2 * 1024 * 1024 * 1024 });

    if (initial_entries > 0) {
        const txn = try Transaction.open(env, .{ .read_only = false });
        errdefer txn.abort();

        var i: u32 = 0;
        var i_buffer: [4]u8 = undefined;
        var hash_buffer: [32]u8 = undefined;
        while (i < initial_entries) : (i += 1) {
            std.mem.writeIntBig(u32, &i_buffer, i);
            std.crypto.hash.Blake3.hash(&i_buffer, &hash_buffer, .{});
            try txn.set(hash_buffer[0..16], hash_buffer[16..32]);
        }

        try txn.commit();
    }

    try env.flush();
    return env;
}
