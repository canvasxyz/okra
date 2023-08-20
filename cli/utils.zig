const std = @import("std");

pub const Encoding = enum { utf8, hex };

var path_buffer: [4096]u8 = undefined;
pub fn resolvePath(dir: std.fs.Dir, name: []const u8) ![*:0]const u8 {
    const path = try dir.realpath(name, &path_buffer);
    path_buffer[path.len] = 0;
    return @as([*:0]const u8, @ptrCast(path_buffer[0..path.len]));
}
