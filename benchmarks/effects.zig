const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");
const okra = @import("okra");

const Sample = @import("Sample.zig");
const utils = @import("utils.zig");

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

    {
        const txn = try env.transaction(.{ .mode = .ReadWrite });
        defer txn.abort();

        const db = try txn.database(null, .{});

        var effects = okra.Effects{};

        var tree = try okra.Tree.init(allocator, db, .{ .effects = &effects });
        defer tree.deinit();

        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            std.mem.writeInt(u32, &seed, i, .big);
            std.crypto.hash.Blake3.hash(&seed, &hash, .{});

            try tree.set(&hash, seed[(seed_size - T)..]);

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
            };
        }
    }

    const final_time = timer.read();
    try log.print("updated {d} random entries in {d}ms\n", .{ iterations, final_time / 1000000 });

    try Sample.printStats(log, samples);
}

pub fn main() !void {
    try testSetEffects(2, 1000);
    try testSetEffects(3, 1000);
}
