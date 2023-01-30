const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

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

var path_buffer: [4096]u8 = undefined;
pub fn resolvePath(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ![:0]u8 {
    const dir_path = try dir.realpath(".", &path_buffer);
    return std.fs.path.joinZ(allocator, &[_][]const u8{ dir_path, name });
}
