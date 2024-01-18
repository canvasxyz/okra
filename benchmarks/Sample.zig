const std = @import("std");

const Sample = @This();

node_count: f64 = 0,
height: f64 = 0,
degree: f64 = 0,
create: f64 = 0,
update: f64 = 0,
delete: f64 = 0,
cursor_ops: f64 = 0,
apply_latency: f64 = 0,
cursor_goto_latency: f64 = 0,
cursor_next_latency: f64 = 0,
cursor_prev_latency: f64 = 0,
cursor_seek_latency: f64 = 0,

pub fn getAverage(samples: []const Sample) Sample {
    const fields = switch (@typeInfo(Sample)) {
        .Struct => |info| info.fields,
        else => @compileError("Sample must be a struct"),
    };

    var avg: Sample = undefined;

    for (samples) |sample| {
        inline for (fields) |field| {
            @field(avg, field.name) += @field(sample, field.name);
        }
    }

    const count: f64 = @floatFromInt(samples.len);
    inline for (fields) |field| {
        @field(avg, field.name) /= count;
    }

    return avg;
}

pub fn getSigma(samples: []const Sample, avg: *const Sample) Sample {
    const fields = switch (@typeInfo(Sample)) {
        .Struct => |info| info.fields,
        else => @compileError("Sample must be a struct"),
    };

    var sigma: Sample = undefined;

    for (samples) |sample| {
        inline for (fields) |field| {
            const delta = @field(sample, field.name) - @field(avg, field.name);
            @field(sigma, field.name) += std.math.pow(f64, delta, 2);
        }
    }

    const count: f64 = @floatFromInt(samples.len);
    inline for (fields) |field| {
        @field(sigma, field.name) = std.math.sqrt(@field(sigma, field.name) / count);
    }

    return sigma;
}
