const std = @import("std");

var path_buffer: [4096]u8 = undefined;
pub fn resolvePath(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ![:0]u8 {
    const dir_path = try dir.realpath(".", &path_buffer);
    return std.fs.path.joinZ(allocator, &[_][]const u8{ dir_path, name });
}