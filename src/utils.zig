const std = @import("std");
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

pub fn hashEntry(key: []const u8, value: []const u8, result: []u8) void {
    var digest = Blake3.init(.{});
    var size: [4]u8 = undefined;
    std.mem.writeIntBig(u32, &size, @intCast(u32, key.len));
    digest.update(&size);
    digest.update(key);
    std.mem.writeIntBig(u32, &size, @intCast(u32, value.len));
    digest.update(&size);
    digest.update(value);
    digest.final(result);
}

pub fn hash(value: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    Blake3.hash(value, &result, .{});
    return result;
}

pub fn parseHash(value: *const [64]u8) [32]u8 {
    var buffer: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

pub fn parseHashLiteral(value: u256) [32]u8 {
    var result: [32]u8 = undefined;
    std.mem.writeIntBig(u256, result[0..32], value);
    return result;
}

var path_buffer: [4096]u8 = undefined;
pub fn resolvePath(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ![:0]u8 {
    const dir_path = try dir.realpath(".", &path_buffer);
    return std.fs.path.joinZ(allocator, &[_][]const u8{ dir_path, name });
}
