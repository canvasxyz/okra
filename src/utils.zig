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
    height: u16,
};

pub fn setMetadata(txn: lmdb.Transaction, metadata: Metadata) !void {
    var value: [5]u8 = undefined;
    value[0] = constants.DATABASE_VERSION;
    value[1] = metadata.degree;
    value[2] = @enumToInt(metadata.variant);
    std.mem.writeIntBig(u16, value[3..5], metadata.height);
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
        const variant = @intToEnum(Variant, value[2]);
        const height = std.mem.readIntBig(u16, value[3..5]);
        return Metadata { .degree = value[1], .variant = variant, .height = height };
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

pub fn getLevel(entry: []const u8) u16 {
    return std.mem.readIntBig(u16, entry[0..2]);
}

pub fn setLevel(entry: []u8, level: u16) void {
    std.mem.writeIntBig(u16, entry[0..2], level);
}

pub fn copy(dst: *std.ArrayList(u8), src: []const u8) !void {
    try dst.resize(src.len);
    std.mem.copy(u8, dst.items, src);
}

// pub fn update(cursor: *lmdb.Cursor, level: u16, variant: Variant, hash: *Sha256) !void {
//     if (level > 0) {
//         const value = try cursor.getCurrentValue();
//         assert(value.len == 32);
//         hash.update(value);
//         return;
//     }

//     switch (variant) {
//         .UnorderedSet => {
//             const value = try cursor.getCurrentValue();
//             assert(value.len == 0);
//         },
//         .UnorderedMap => {
            
//         },
//         .OrderedSet => {
            
//         },
//         .OrderedMap => {
            
//         },
//     }
// }