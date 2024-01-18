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
const Sample = @import("Sample.zig");

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

    timer.reset();

    {
        const txn = try env.transaction(.{ .mode = .ReadWrite });
        defer txn.abort();

        var apply_timer = try std.time.Timer.start();

        const db = try txn.database(null, .{});

        var effects = try okra.Effects.init();
        var sl = try okra.SkipList.init(allocator, db, .{ .effects = &effects });
        defer sl.deinit();

        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            std.mem.writeInt(u32, &seed, i, .big);
            std.crypto.hash.Blake3.hash(&seed, &hash, .{});

            apply_timer.reset();
            try sl.set(&hash, seed[(seed_size - T)..]);
            const t: f64 = @floatFromInt(apply_timer.read());

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
                .cursor_goto_latency = effects.cursor_goto_latency,
                .cursor_next_latency = effects.cursor_next_latency,
                .cursor_prev_latency = effects.cursor_prev_latency,
                .cursor_seek_latency = effects.cursor_seek_latency,
                .apply_latency = t / 1_000_000,
            };
        }
    }

    const final_time = timer.read();
    try log.print("updated {d} random entries in {d}ms\n", .{ iterations, final_time / 1000000 });

    const avg = Sample.getAverage(samples);
    const sigma = Sample.getSigma(samples, &avg);

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
    try log.print("apply      | {d: >12.3} | {d: >6.3}\n", .{ avg.apply_latency, sigma.apply_latency });
    try log.print("---------- | {s:->12} | {s:->6}\n", .{ "", "" });
    try log.print("goto       | {d: >12.3} | {d: >6.3}\n", .{ avg.cursor_goto_latency, sigma.cursor_goto_latency });
    try log.print("next       | {d: >12.3} | {d: >6.3}\n", .{ avg.cursor_next_latency, sigma.cursor_next_latency });
    try log.print("prev       | {d: >12.3} | {d: >6.3}\n", .{ avg.cursor_prev_latency, sigma.cursor_prev_latency });
    try log.print("seek       | {d: >12.3} | {d: >6.3}\n", .{ avg.cursor_seek_latency, sigma.cursor_seek_latency });

    const total_latency = avg.cursor_goto_latency + avg.cursor_next_latency + avg.cursor_prev_latency + avg.cursor_seek_latency;
    try log.print("total      | {d: >12.3} |\n", .{total_latency});
}

pub fn main() !void {
    try testSetEffects(2, 1000);
    // try testSetEffects(3, 1000);
}
