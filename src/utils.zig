const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("lmdb");

const constants = @import("./constants.zig");

pub const Variant = enum(u8) {
    UnorderedSet,
    UnorderedMap,
    OrderedSet,
    OrderedMap,
};

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
        if (value.len < 3) {
            return error.InvalidDatabase;
        } else if (value[0] != constants.DATABASE_VERSION) {
            return error.UnsupportedVersion;
        } else {
            const degree = value[1];
            const variant = @intToEnum(Variant, value[2]);
            const height = value[3];
            return Metadata { .degree = degree, .variant = variant, .height = height };
        }
    } else {
        return null;
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
