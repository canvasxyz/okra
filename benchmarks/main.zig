const std = @import("std");
const allocator = std.heap.c_allocator;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");
const okra = @import("okra");

const value_size = 8;

var prng = std.rand.DefaultPrng.init(0x0000000000000000);
var random = prng.random();

const ms: f64 = 1_000_000.0;

pub fn main() !void {
    const log = std.io.getStdOut().writer();

    _ = try log.write("## Benchmarks\n\n");
    try Context.exec("1k entries", 1_000, log, .{});
    _ = try log.write("\n");
    try Context.exec("50k entries", 50_000, log, .{ .map_size = 2 * 1024 * 1024 * 1024 });
    _ = try log.write("\n");
    try Context.exec("1m entries", 1_000_000, log, .{ .map_size = 2 * 1024 * 1024 * 1024 });
}

const Context = struct {
    env: lmdb.Environment,
    name: []const u8,
    size: u32,
    log: std.fs.File.Writer,

    pub fn exec(name: []const u8, size: u32, log: std.fs.File.Writer, options: lmdb.Environment.EnvironmentOptions) !void {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const env = try lmdb.Environment.openDir(tmp.dir, options);
        defer env.close();

        const ctx = Context{ .env = env, .name = name, .size = size, .log = log };
        try ctx.initialize();
        try ctx.printHeader();

        try ctx.getRandomEntries("get random 1 entry", 100, 1);
        try ctx.getRandomEntries("get random 100 entries", 100, 100);
        try iterateEntries(ctx, 100);
        try ctx.setRandomEntries("set random 1 entry", 100, 1);
        try ctx.setRandomEntries("set random 100 entries", 100, 100);
        try ctx.setRandomEntries("set random 1k entries", 10, 1_000);
        try ctx.setRandomEntries("set random 50k entries", 10, 50_000);
    }

    fn initialize(ctx: Context) !void {
        const txn = try lmdb.Transaction.open(ctx.env, .{ .mode = .ReadWrite });
        errdefer txn.abort();

        const dbi = try txn.openDatabase(null, .{});

        var builder = try okra.Builder.open(allocator, txn, dbi, .{});

        var key: [4]u8 = undefined;
        var value: [value_size]u8 = undefined;

        var i: u32 = 0;
        while (i < ctx.size) : (i += 1) {
            std.mem.writeIntBig(u32, &key, i);
            std.crypto.hash.Blake3.hash(&key, &value, .{});
            try builder.set(&key, &value);
        }

        try builder.build();

        try txn.commit();
        try ctx.env.flush();
    }

    fn printHeader(ctx: Context) !void {
        try ctx.log.print("### {s}\n\n", .{ctx.name});
        try ctx.log.print(
            "| {s: <30} | {s: >10} | {s: >10} | {s: >10} | {s: >10} | {s: >8} | {s: >10} |\n",
            .{ "", "iterations", "min (ms)", "max (ms)", "avg (ms)", "std", "ops / s" },
        );
        try ctx.log.print(
            "| {s:-<30} | {s:->10} | {s:->10} | {s:->10} | {s:->10} | {s:->8} | {s:->10} |\n",
            .{ ":", ":", ":", ":", ":", ":", ":" },
        );
    }

    fn getRandomEntries(ctx: Context, comptime name: []const u8, comptime iterations: u32, comptime batch_size: usize) !void {
        var runtimes: [iterations]f64 = undefined;
        var timer = try std.time.Timer.start();

        var operations: usize = 0;
        for (&runtimes) |*t| {
            timer.reset();
            operations += batch_size;

            const txn = try lmdb.Transaction.open(ctx.env, .{ .mode = .ReadOnly });
            defer txn.abort();

            const dbi = try txn.openDatabase(null, .{});

            {
                var tree = try okra.Tree.open(allocator, txn, dbi, .{});
                defer tree.close();

                var key: [4]u8 = undefined;

                var n: u32 = 0;
                while (n < batch_size) : (n += 1) {
                    std.mem.writeIntBig(u32, &key, random.uintLessThan(u32, ctx.size));
                    const value = try tree.get(&key);
                    std.debug.assert(value.?.len == value_size);
                }
            }

            t.* = @as(f64, @floatFromInt(timer.read())) / ms;
        }

        try ctx.printRow(name, &runtimes, operations);
    }

    fn setRandomEntries(ctx: Context, comptime name: []const u8, comptime iterations: u32, comptime batch_size: usize) !void {
        var runtimes: [iterations]f64 = undefined;
        var timer = try std.time.Timer.start();

        var operations: usize = 0;
        for (&runtimes, 0..) |*t, i| {
            timer.reset();

            const txn = try lmdb.Transaction.open(ctx.env, .{ .mode = .ReadWrite });
            errdefer txn.abort();

            const dbi = try txn.openDatabase(null, .{});

            {
                var tree = try okra.Tree.open(allocator, txn, dbi, .{});
                defer tree.close();

                var key: [4]u8 = undefined;
                var seed: [12]u8 = undefined;
                var value: [8]u8 = undefined;

                std.mem.writeIntBig(u32, seed[0..4], ctx.size);
                std.mem.writeIntBig(u32, seed[4..8], @as(u32, @intCast(i)));

                var n: u32 = 0;
                while (n < batch_size) : (n += 1) {
                    std.mem.writeIntBig(u32, &key, random.uintLessThan(u32, ctx.size));
                    std.mem.writeIntBig(u32, seed[8..], n);
                    std.crypto.hash.Blake3.hash(&seed, &value, .{});
                    try tree.set(&key, &value);
                }
            }

            try txn.commit();
            try ctx.env.flush();

            t.* = @as(f64, @floatFromInt(timer.read())) / ms;
            operations += batch_size;
        }

        try ctx.printRow(name, &runtimes, operations);
    }

    fn iterateEntries(ctx: Context, comptime iterations: u32) !void {
        var runtimes: [iterations]f64 = undefined;
        var timer = try std.time.Timer.start();

        var operations: usize = 0;
        for (&runtimes) |*t| {
            timer.reset();
            operations += ctx.size;

            const txn = try lmdb.Transaction.open(ctx.env, .{ .mode = .ReadOnly });
            defer txn.abort();

            const dbi = try txn.openDatabase(null, .{});

            {
                var tree = try okra.Tree.open(allocator, txn, dbi, .{});
                defer tree.close();

                var iterator = try okra.Iterator.open(allocator, &tree, .{
                    .level = 0,
                    .lower_bound = .{ .key = null, .inclusive = false },
                });

                defer iterator.close();

                while (try iterator.next()) |node| {
                    std.debug.assert(node.key.?.len == 4);
                    std.debug.assert(node.value != null);
                }
            }

            t.* = @as(f64, @floatFromInt(timer.read())) / ms;
        }

        try ctx.printRow("iterate over all entries", &runtimes, operations);
    }

    pub fn printRow(ctx: Context, name: []const u8, runtimes: []const f64, operations: usize) !void {
        var sum: f64 = 0;
        var min: f64 = @as(f64, @floatFromInt(std.math.maxInt(u64)));
        var max: f64 = 0;
        for (runtimes) |t| {
            sum += t;
            if (t < min) min = t;
            if (t > max) max = t;
        }

        const avg = sum / @as(f64, @floatFromInt(runtimes.len));

        var sum_sq: f64 = 0;
        for (runtimes) |t| {
            const delta = t - avg;
            sum_sq += delta * delta;
        }

        const std_dev = std.math.sqrt(sum_sq / @as(f64, @floatFromInt(runtimes.len)));
        const ops_per_second = @as(f64, @floatFromInt(operations * 1_000)) / sum;

        try ctx.log.print(
            "| {s: <30} | {d: >10} | {d: >10.4} | {d: >10.4} | {d: >10.4} | {d: >8.4} | {d: >10.0} |\n",
            .{ name, runtimes.len, min, max, avg, std_dev, ops_per_second },
        );
    }
};
