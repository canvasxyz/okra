const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const Sha256 = std.crypto.hash.sha2.Sha256;
const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");
const okra = @import("okra");

const utils = @import("utils.zig");

const Sample = struct {
    node_count: f64 = 0,
    height: f64 = 0,
    degree: f64 = 0,
    create: f64 = 0,
    update: f64 = 0,
    delete: f64 = 0,
    cursor_ops: f64 = 0,
};

fn testSetEffects(comptime T: u8, iterations: u32) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const log = std.io.getStdOut().writer();
    try log.writeByte('\n');

    const env = try utils.open(tmp.dir, .{ .map_size = 2 * 1024 * 1024 * 1024 });
    defer env.deinit();

    const entry_count = std.math.pow(u32, 2, 8 * T);
    const seed_size = 4;
    var seed: [seed_size]u8 = undefined;
    var hash = [_]u8{0xff} ** T;

    var timer = try std.time.Timer.start();
    {
        const txn = try env.transaction(.{ .mode = .ReadWrite });
        errdefer txn.abort();

        const db = try txn.database(null, .{});
        var builder = try okra.Builder.init(allocator, db, .{});
        defer builder.deinit();

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            std.mem.writeInt(u32, &seed, i, .big);
            try builder.set(seed[(seed_size - T)..], &hash);
        }

        try builder.build();
        try txn.commit();
    }

    try env.sync();

    const init_time = timer.lap();
    try log.print("initialized {d} entries in {d}ms\n", .{ entry_count, init_time / 1000000 });

    const samples = try allocator.alloc(Sample, iterations);
    defer allocator.free(samples);

    var avg = Sample{};

    {
        const txn = try env.transaction(.{ .mode = .ReadWrite });
        defer txn.abort();

        const db = try txn.database(null, .{});

        var effects = okra.Effects{};
        var tree = try okra.Tree.init(allocator, db, .{ .effects = &effects });
        defer tree.deinit();

        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            {
                std.mem.writeInt(u32, &seed, i, .big);
                std.crypto.hash.Blake3.hash(&seed, &hash, .{});
                try tree.set(&hash, seed[(seed_size - T)..]);
            }

            const stat = try env.stat();

            const parent_count: f64 = @floatFromInt(stat.entries - entry_count);
            const node_count: f64 = @floatFromInt(stat.entries - 2);

            samples[i] = Sample{
                .node_count = @floatFromInt(stat.entries - 1),
                .height = @floatFromInt(effects.height),
                .degree = node_count / parent_count,
                .create = @floatFromInt(effects.create),
                .update = @floatFromInt(effects.update),
                .delete = @floatFromInt(effects.delete),
                .cursor_ops = @floatFromInt(effects.cursor_ops),
            };

            avg.node_count += samples[i].node_count;
            avg.height += samples[i].height;
            avg.degree += samples[i].degree;
            avg.create += samples[i].create;
            avg.update += samples[i].update;
            avg.delete += samples[i].delete;
            avg.cursor_ops += samples[i].cursor_ops;
        }
    }

    const final_time = timer.read();
    try log.print("updated {d} random entries in {d}ms\n", .{ iterations, final_time / 1000000 });

    const iters = @as(f64, @floatFromInt(iterations));
    avg.node_count /= iters;
    avg.height /= iters;
    avg.degree /= iters;
    avg.create /= iters;
    avg.update /= iters;
    avg.delete /= iters;
    avg.cursor_ops /= iters;

    var sigma = Sample{};
    for (samples) |sample| {
        sigma.node_count += std.math.pow(f64, sample.node_count - avg.node_count, 2);
        sigma.height += std.math.pow(f64, sample.height - avg.height, 2);
        sigma.degree += std.math.pow(f64, sample.degree - avg.degree, 2);
        sigma.create += std.math.pow(f64, sample.create - avg.create, 2);
        sigma.update += std.math.pow(f64, sample.update - avg.update, 2);
        sigma.delete += std.math.pow(f64, sample.delete - avg.delete, 2);
        sigma.cursor_ops += std.math.pow(f64, sample.cursor_ops - avg.cursor_ops, 2);
    }

    sigma.node_count = std.math.sqrt(sigma.node_count / iters);
    sigma.height = std.math.sqrt(sigma.height / iters);
    sigma.degree = std.math.sqrt(sigma.degree / iters);
    sigma.create = std.math.sqrt(sigma.create / iters);
    sigma.update = std.math.sqrt(sigma.update / iters);
    sigma.delete = std.math.sqrt(sigma.delete / iters);
    sigma.cursor_ops = std.math.sqrt(sigma.cursor_ops / iters);

    try log.writeByte('\n');
    try log.print("           | {s: >12} | {s: >6}\n", .{ "avg", "std" });
    try log.print("---------- | {s:->12} | {s:->6}\n", .{ "", "" });
    try log.print("height     | {d: >12.3} | {d: >6.3}\n", .{ avg.height, sigma.height });
    try log.print("node count | {d: >12.3} | {d: >6.3}\n", .{ avg.node_count, sigma.node_count });
    try log.print("avg degree | {d: >12.3} | {d: >6.3}\n", .{ avg.degree, sigma.degree });
    try log.print("created    | {d: >12.3} | {d: >6.3}\n", .{ avg.create, sigma.create });
    try log.print("updated    | {d: >12.3} | {d: >6.3}\n", .{ avg.update, sigma.update });
    try log.print("deleted    | {d: >12.3} | {d: >6.3}\n", .{ avg.delete, sigma.delete });
    try log.print("cursor ops | {d: >12.3} | {d: >6.3}\n", .{ avg.cursor_ops, sigma.cursor_ops });
}

pub fn main() !void {
    try testSetEffects(2, 1000);
    // try testSetEffects(3, 1000);
}
