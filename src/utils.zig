const std = @import("std");

pub fn parseHash(hash: *const [64]u8) [32]u8 {
  var buffer: [32]u8 = undefined;
  _ = std.fmt.hexToBytes(&buffer, hash) catch unreachable;
  return buffer;
}

pub var pathBuffer: [4096]u8 = undefined;

pub fn resolvePath(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ![:0]u8 {
  const dirPath = try dir.realpath(".", &pathBuffer);
  return std.fs.path.joinZ(allocator, &[_][]const u8{ dirPath, name });
}
