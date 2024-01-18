const std = @import("std");

const utils = @import("utils.zig");

const Sample = @This();

node_count: f64 = 0,
height: f64 = 0,
degree: f64 = 0,
create: f64 = 0,
update: f64 = 0,
delete: f64 = 0,

pub fn printStats(log: std.fs.File.Writer, samples: []const Sample) !void {
    const avg = utils.getAverage(Sample, samples);
    const sigma = utils.getSigma(Sample, samples, &avg);

    try log.writeByte('\n');
    try log.print("           | {s: >12} | {s: >6}\n", .{ "avg", "std" });
    try log.print("---------- | {s:->12} | {s:->6}\n", .{ "", "" });
    try log.print("height     | {d: >12.3} | {d: >6.3}\n", .{ avg.height, sigma.height });
    try log.print("node count | {d: >12.3} | {d: >6.3}\n", .{ avg.node_count, sigma.node_count });
    try log.print("avg degree | {d: >12.3} | {d: >6.3}\n", .{ avg.degree, sigma.degree });
    try log.print("created    | {d: >12.3} | {d: >6.3}\n", .{ avg.create, sigma.create });
    try log.print("updated    | {d: >12.3} | {d: >6.3}\n", .{ avg.update, sigma.update });
    try log.print("deleted    | {d: >12.3} | {d: >6.3}\n", .{ avg.delete, sigma.delete });
}
