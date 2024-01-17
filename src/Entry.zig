const std = @import("std");

const Entry = @This();

key: []const u8,
value: []const u8,

pub fn hash(key: []const u8, value: []const u8, result: []u8) void {
    var digest = std.crypto.hash.Blake3.init(.{});
    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, @as(u32, @intCast(key.len)), .big);
    digest.update(&size);
    digest.update(key);
    std.mem.writeInt(u32, &size, @as(u32, @intCast(value.len)), .big);
    digest.update(&size);
    digest.update(value);
    digest.final(result);
}
