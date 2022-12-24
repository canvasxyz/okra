const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("lmdb");

const constants = @import("constants.zig");

pub const Variant = enum(u8) { Set, SetIndex, Map, MapIndex };

pub const Metadata = struct {
    degree: u8,
    variant: Variant,
    height: u8,
};

pub fn setMetadata(txn: lmdb.Transaction, metadata: Metadata) !void {
    var value: [4]u8 = undefined;
    value[0] = constants.DATABASE_VERSION;
    value[1] = metadata.degree;
    value[2] = @enumToInt(metadata.variant);
    value[3] = metadata.height;
    try txn.set(&constants.METADATA_KEY, &value);
}

pub fn getMetadata(txn: lmdb.Transaction) !?Metadata {
    if (try txn.get(&constants.METADATA_KEY)) |value| {
        return try parseMetadata(value);
    } else {
        return null;
    }
}

pub fn parseMetadata(value: []const u8) !Metadata {
    if (value.len < 3) {
        return error.InvalidDatabase;
    } else if (value[0] != constants.DATABASE_VERSION) {
        return error.UnsupportedVersion;
    } else {
        const degree = value[1];
        const variant = @intToEnum(Variant, value[2]);
        const height = value[3];
        return Metadata{ .degree = degree, .variant = variant, .height = height };
    }
}

pub fn hash(value: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    Sha256.hash(value, &result, .{});
    return result;
}

pub fn parseHash(value: *const [64]u8) [32]u8 {
    var buffer: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

var path_buffer: [4096]u8 = undefined;
pub fn resolvePath(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ![:0]u8 {
    const dir_path = try dir.realpath(".", &path_buffer);
    return std.fs.path.joinZ(allocator, &[_][]const u8{ dir_path, name });
}

pub fn copy(dst: *std.ArrayList(u8), src: []const u8) !void {
    try dst.resize(src.len);
    std.mem.copy(u8, dst.items, src);
}

pub fn getLimit(degree: u8) !u8 {
    if (degree == 0) {
        return error.InvalidDegree;
    }

    return @intCast(u8, 256 / @intCast(u16, degree));
}

pub fn getNodeHash(variant: Variant, level: u8, key: []const u8, value: []const u8) !*const [32]u8 {
    if (level == 0) {
        switch (variant) {
            Variant.Set => if (key.len == 32) return key[0..32],
            Variant.SetIndex => if (key.len == 32 and value.len == 0) return key[0..32],
            Variant.Map => if (value.len >= 32) return value[0..32],
            Variant.MapIndex => if (value.len == 32) return value[0..32],
        }
    } else if (value.len == 32) {
        return value[0..32];
    }

    return error.InvalidDatabase;
}
