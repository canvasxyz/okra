const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const Entry = @This();

key: []const u8,
value: []const u8,

pub fn hash(key: []const u8, value: []const u8, result: []u8) void {
    var hash_buffer: [Sha256.digest_length]u8 = undefined;
    var digest = Sha256.init(.{});
    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, @intCast(key.len), .big);
    digest.update(&size);
    digest.update(key);
    std.mem.writeInt(u32, &size, @intCast(value.len), .big);
    digest.update(&size);
    digest.update(value);
    digest.final(&hash_buffer);
    @memcpy(result, hash_buffer[0..result.len]);
}
