const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const Sha256 = std.crypto.hash.sha2.Sha256;
const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");
const okra = @import("okra");

const Sample = struct {
    node_count: f64 = 0,
    height: f64 = 0,
    degree: f64 = 0,
    create: f64 = 0,
    update: f64 = 0,
    delete: f64 = 0,
};

fn testSetEffects(comptime T: u8, iterations: u32) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const log = std.io.getStdOut().writer();
    _ = try log.write("\n");

    const env = try lmdb.Environment.openDir(tmp.dir, .{ .map_size = 2 * 1024 * 1024 * 1024 });
    defer env.close();

    const entry_count = std.math.pow(u32, 2, 8 * T);
    const seed_size = 4;
    var seed: [seed_size]u8 = undefined;
    var hash = [_]u8{0xff} ** T;

    var timer = try std.time.Timer.start();
    {
        const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadWrite });
        errdefer txn.abort();

        var builder = try okra.Builder.open(allocator, .{ .txn = txn });
        defer builder.deinit();

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            std.mem.writeIntBig(u32, &seed, i);
            try builder.set(seed[(seed_size - T)..], &hash);
        }

        try builder.build();
        try txn.commit();
    }

    try env.flush();

    const init_time = timer.lap();
    try log.print("initialized {d} entries in {d}ms\n", .{ entry_count, init_time / 1000000 });

    var avg = Sample{};
    var samples = std.ArrayList(Sample).init(allocator);
    defer samples.deinit();

    {
        const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadWrite });
        defer txn.abort();

        var effects = okra.Effects{};
        var tree = try okra.Tree.open(allocator, txn, .{ .effects = &effects });
        defer tree.close();

        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            {
                std.mem.writeIntBig(u32, &seed, i);
                std.crypto.hash.Blake3.hash(&seed, &hash, .{});
                try tree.set(&hash, seed[(seed_size - T)..]);
            }

            const stat = try env.stat();
            const sample = Sample{
                .node_count = @as(f64, @floatFromInt(stat.entries - 1)),
                .height = @as(f64, @floatFromInt(effects.height)),
                .degree = @as(f64, @floatFromInt(stat.entries - 2)) / @as(f64, @floatFromInt(stat.entries - entry_count)),
                .create = @as(f64, @floatFromInt(effects.create)),
                .update = @as(f64, @floatFromInt(effects.update)),
                .delete = @as(f64, @floatFromInt(effects.delete)),
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

    const iters = @as(f64, @floatFromInt(iterations));
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

pub fn main() !void {
    try testSetEffects(2, 1000);
    try testSetEffects(3, 1000);
}
