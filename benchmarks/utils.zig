const std = @import("std");

var path_buffer: [4096]u8 = undefined;

pub fn resolvePath(dir: *std.fs.Dir, name: []const u8) ![*:0]const u8 {
    const path = try dir.realpath(name, &path_buffer);
    path_buffer[path.len] = 0;
    return @as([*:0]const u8, @ptrCast(path_buffer[0..path.len]));
}

pub fn printRow(log: std.fs.File.Writer, name: []const u8, runtimes: []const f64, operations: usize) !void {
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

    try log.print(
        "| {s: <30} | {d: >10} | {d: >10.4} | {d: >10.4} | {d: >10.4} | {d: >8.4} | {d: >10.0} |\n",
        .{ name, runtimes.len, min, max, avg, std_dev, ops_per_second },
    );
}
