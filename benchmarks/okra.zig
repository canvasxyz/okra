const std = @import("std");
const allocator = std.heap.c_allocator;
const hex = std.fmt.fmtSliceHexLower;

const okra = @import("okra");
const utils = @import("utils.zig");

const data_directory_name = "data";
const value_size = 8;

const Context = struct {
    tree: *okra.Tree,
    size: u32,
    log: std.fs.File.Writer,

    pub fn exec(ctx: Context) !void {
        try ctx.initialize();
        try ctx.printHeader();
        try ctx.runTests("read 1 random entry", ReadRandomEntries(1).run, 100);
        try ctx.runTests("read 100 random entries", ReadRandomEntries(100).run, 100);
        try ctx.runTests("iterate over all entries", iterateOverEntries, 100);
        try ctx.runTests("set 1 random entry", SetRandomEntries(1).run, 100);
        try ctx.runTests("set 1,000 random entries", SetRandomEntries(1_000).run, 10);
        try ctx.runTests("set 50,000 random entries", SetRandomEntries(50_000).run, 10);
    }

    fn initialize(ctx: Context) !void {
        var builder = try okra.Builder.open(allocator, ctx.tree.env, .{});
        errdefer builder.abort();

        var key: [4]u8 = undefined;
        var value: [value_size]u8 = undefined;

        var i: u32 = 0;
        while (i < ctx.size) : (i += 1) {
            std.mem.writeIntBig(u32, &key, i);
            std.crypto.hash.Blake3.hash(&key, &value, .{});
            try builder.set(&key, &value);
        }

        try builder.commit();
        try ctx.tree.env.flush();
    }

    fn printHeader(ctx: Context) !void {
        try ctx.log.print("\n### DB size: {d} entries\n\n", .{ctx.size});
        try ctx.log.print(
            "| {s: <30} | {s: >10} | {s: >10} | {s: >10} | {s: >10} | {s: >8} | {s: >10} |\n",
            .{ "", "iterations", "min (ms)", "max (ms)", "avg (ms)", "std", "ops / s" },
        );
        try ctx.log.print(
            "| {s:-<30} | {s:->10} | {s:->10} | {s:->10} | {s:->10} | {s:->8} | {s:->10} |\n",
            .{ ":", ":", ":", ":", ":", ":", ":" },
        );
    }

    const ms: f64 = 1_000_000.0;
    fn runTests(
        ctx: Context,
        comptime name: []const u8,
        comptime run: fn (ctx: Context, i: u32) anyerror!u64,
        comptime iterations: u32,
    ) !void {
        var runtimes: [iterations]f64 = undefined;
        var timer = try std.time.Timer.start();

        var operations: usize = 0;
        for (runtimes) |*t, i| {
            timer.reset();
            operations += try run(ctx, @intCast(u32, i));
            try ctx.tree.env.flush();
            t.* = @intToFloat(f64, timer.read()) / ms;
        }

        try utils.printRow(ctx.log, name, &runtimes, operations);
    }
};

test "benchmark" {
    const log = std.io.getStdErr().writer();
    try log.print("\n", .{});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const name = "iota-1000";
        try tmp.dir.makeDir(name);
        const path = try utils.resolvePath(&tmp.dir, name);
        var tree = try okra.Tree.open(allocator, path, .{});
        defer tree.close();

        const ctx = Context{ .tree = &tree, .size = 1_000, .log = log };
        try ctx.exec();
    }

    {
        const name = "iota-50000";
        try tmp.dir.makeDir(name);
        const path = try utils.resolvePath(&tmp.dir, name);
        var tree = try okra.Tree.open(allocator, path, .{ .map_size = 2 * 1024 * 1024 * 1024 });
        defer tree.close();

        const ctx = Context{ .tree = &tree, .size = 50_000, .log = log };
        try ctx.exec();
    }

    {
        const name = "iota-1000000";
        try tmp.dir.makeDir(name);
        const path = try utils.resolvePath(&tmp.dir, name);
        var tree = try okra.Tree.open(allocator, path, .{ .map_size = 2 * 1024 * 1024 * 1024 });
        defer tree.close();

        const ctx = Context{ .tree = &tree, .size = 1_000_000, .log = log };
        try ctx.exec();
    }
}

var prng = std.rand.DefaultPrng.init(0x0000000000000000);
var random = prng.random();

fn SetRandomEntries(comptime batch_size: u32) type {
    return struct {
        pub fn run(ctx: Context, i: u32) !usize {
            var txn = try okra.Transaction.open(allocator, ctx.tree, .{ .mode = .ReadWrite });
            errdefer txn.abort();

            var key: [4]u8 = undefined;
            var seed: [12]u8 = undefined;
            var value: [8]u8 = undefined;

            std.mem.writeIntBig(u32, seed[0..4], ctx.size);
            std.mem.writeIntBig(u32, seed[4..8], i);

            var n: u32 = 0;
            while (n < batch_size) : (n += 1) {
                std.mem.writeIntBig(u32, &key, random.uintLessThan(u32, ctx.size));
                std.mem.writeIntBig(u32, seed[8..], n);
                std.crypto.hash.Blake3.hash(&seed, &value, .{});
                try txn.set(&key, &value);
            }

            try txn.commit();

            return batch_size;
        }
    };
}

fn ReadRandomEntries(comptime batch_size: u32) type {
    return struct {
        pub fn run(ctx: Context, _: u32) !usize {
            var txn = try okra.Transaction.open(allocator, ctx.tree, .{ .mode = .ReadOnly });
            defer txn.abort();

            var key: [4]u8 = undefined;

            var n: u32 = 0;
            while (n < batch_size) : (n += 1) {
                std.mem.writeIntBig(u32, &key, random.uintLessThan(u32, ctx.size));
                const value = try txn.get(&key);
                std.debug.assert(value.?.len == value_size);
            }

            return batch_size;
        }
    };
}

fn iterateOverEntries(ctx: Context, _: u32) !usize {
    var txn = try okra.Transaction.open(allocator, ctx.tree, .{ .mode = .ReadOnly });
    defer txn.abort();

    var iterator = try okra.Iterator.open(allocator, &txn, .{ .level = 0 });
    defer iterator.close();

    while (try iterator.next()) |node| {
        std.debug.assert(node.key == null or node.value != null);
    }

    return ctx.size;
}
