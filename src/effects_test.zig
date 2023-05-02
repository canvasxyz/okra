const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const Sha256 = std.crypto.hash.sha2.Sha256;
const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");

const utils = @import("utils.zig");

const Sample = struct {
    node_count: f64 = 0,
    height: f64 = 0,
    degree: f64 = 0,
    create: f64 = 0,
    update: f64 = 0,
    delete: f64 = 0,
};

fn testSetEffects(comptime K: u8, comptime Q: u32, comptime T: u8, iterations: u32) !void {
    const Tree = @import("tree.zig").Tree(K, Q);
    const Builder = @import("builder.zig").Builder(K, Q);
    const Transaction = @import("transaction.zig").Transaction(K, Q);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const log = std.io.getStdErr().writer();
    _ = try log.write("\n\n");

    const path = try utils.resolvePath(tmp.dir, ".");
    var tree = try Tree.open(allocator, path, .{ .map_size = 2 * 1024 * 1024 * 1024 });
    defer tree.close();

    const entry_count = std.math.pow(u32, 2, 8 * T);
    const seed_size = 4;
    var seed: [seed_size]u8 = undefined;
    var hash = [_]u8{0xff} ** T;

    var timer = try std.time.Timer.start();
    {
        var builder = try Builder.open(allocator, tree.env, .{});
        errdefer builder.abort();
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            std.mem.writeIntBig(u32, &seed, i);
            try builder.set(seed[(seed_size - T)..], &hash);
        }

        try builder.commit();
        try tree.env.flush();
    }

    const init_time = timer.lap();
    try log.print("initialized {d} entries in {d}ms\n", .{ entry_count, init_time / 1000000 });

    var avg = Sample{};
    var samples = std.ArrayList(Sample).init(allocator);
    defer samples.deinit();

    {
        var effects = Transaction.Effects{};
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            {
                var txn = try Transaction.open(allocator, &tree, .{ .mode = .ReadWrite, .effects = &effects });
                errdefer txn.abort();
                std.mem.writeIntBig(u32, &seed, i);
                std.crypto.hash.Blake3.hash(&seed, &hash, .{});
                try txn.set(&hash, seed[(seed_size - T)..]);
                try txn.commit();
            }

            const stat = try tree.env.stat();
            const sample = Sample{
                .node_count = @intToFloat(f64, stat.entries - 1),
                .height = @intToFloat(f64, effects.height),
                .degree = @intToFloat(f64, stat.entries - 2) / @intToFloat(f64, stat.entries - entry_count),
                .create = @intToFloat(f64, effects.create),
                .update = @intToFloat(f64, effects.update),
                .delete = @intToFloat(f64, effects.delete),
            };

            avg.node_count += sample.node_count;
            avg.height += sample.height;
            avg.degree += sample.degree;
            avg.create += sample.create;
            avg.update += sample.update;
            avg.delete += sample.delete;

            try samples.append(sample);
        }
    }

    const final_time = timer.read();
    try log.print("updated {d} random entries in {d}ms\n", .{ iterations, final_time / 1000000 });

    const iters = @intToFloat(f64, iterations);
    avg.node_count = avg.node_count / iters;
    avg.height = avg.height / iters;
    avg.degree = avg.degree / iters;
    avg.create = avg.create / iters;
    avg.update = avg.update / iters;
    avg.delete = avg.delete / iters;

    var sigma = Sample{};
    for (samples.items) |sample| {
        sigma.node_count += std.math.pow(f64, sample.node_count - avg.node_count, 2);
        sigma.height += std.math.pow(f64, sample.height - avg.height, 2);
        sigma.degree += std.math.pow(f64, sample.degree - avg.degree, 2);
        sigma.create += std.math.pow(f64, sample.create - avg.create, 2);
        sigma.update += std.math.pow(f64, sample.update - avg.update, 2);
        sigma.delete += std.math.pow(f64, sample.delete - avg.delete, 2);
    }

    sigma.node_count = std.math.sqrt(sigma.node_count / iters);
    sigma.height = std.math.sqrt(sigma.height / iters);
    sigma.degree = std.math.sqrt(sigma.degree / iters);
    sigma.create = std.math.sqrt(sigma.create / iters);
    sigma.update = std.math.sqrt(sigma.update / iters);
    sigma.delete = std.math.sqrt(sigma.delete / iters);

    _ = try log.write("\n");
    try log.print("           | {s: >12} | {s: >6}\n", .{ "avg", "std" });
    try log.print("---------- | {s:->12} | {s:->6}\n", .{ "", "" });
    try log.print("height     | {d: >12.3} | {d: >6.3}\n", .{ avg.height, sigma.height });
    try log.print("node count | {d: >12.3} | {d: >6.3}\n", .{ avg.node_count, sigma.node_count });
    try log.print("avg degree | {d: >12.3} | {d: >6.3}\n", .{ avg.degree, sigma.degree });
    try log.print("created    | {d: >12.3} | {d: >6.3}\n", .{ avg.create, sigma.create });
    try log.print("updated    | {d: >12.3} | {d: >6.3}\n", .{ avg.update, sigma.update });
    try log.print("deleted    | {d: >12.3} | {d: >6.3}\n", .{ avg.delete, sigma.delete });
}

test "average 1000 random set effects on 65536 entries with Q=4" {
    try testSetEffects(16, 4, 2, 1000);
}

test "average 1000 random set effects on 16777216 entries with Q=32" {
    try testSetEffects(16, 32, 3, 1000);
}
