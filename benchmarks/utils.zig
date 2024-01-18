const std = @import("std");

const lmdb = @import("lmdb");
const okra = @import("okra");
const Sample = @import("Sample.zig");

var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;

pub fn open(dir: std.fs.Dir, options: lmdb.Environment.Options) !lmdb.Environment {
    const path = try dir.realpath(".", &path_buffer);
    path_buffer[path.len] = 0;
    return try lmdb.Environment.init(path_buffer[0..path.len :0], options);
}

pub fn getAverage(comptime T: type, samples: []const T) T {
    const fields = switch (@typeInfo(T)) {
        .Struct => |info| info.fields,
        else => @compileError("Sample type must be a struct"),
    };

    var avg: T = undefined;

    for (samples) |*sample| {
        inline for (fields) |field| {
            if (field.type == f64 or field.type == f32) {
                @field(avg, field.name) += @field(sample, field.name);
            }
        }
    }

    const count: f64 = @floatFromInt(samples.len);
    inline for (fields) |field| {
        if (field.type == f64 or field.type == f32) {
            @field(avg, field.name) /= count;
        }
    }

    return avg;
}

pub fn getSigma(comptime T: type, samples: []const T, avg: *const T) T {
    const fields = switch (@typeInfo(T)) {
        .Struct => |info| info.fields,
        else => @compileError("Sample type must be a struct"),
    };

    var sigma: T = undefined;

    for (samples) |*sample| {
        inline for (fields) |field| {
            if (field.type == f64 or field.type == f32) {
                const delta = @field(sample, field.name) - @field(avg, field.name);
                @field(sigma, field.name) += std.math.pow(f64, delta, 2);
            }
        }
    }

    const count: f64 = @floatFromInt(samples.len);
    inline for (fields) |field| {
        if (field.type == f64 or field.type == f32) {
            @field(sigma, field.name) = std.math.sqrt(@field(sigma, field.name) / count);
        }
    }

    return sigma;
}
