const std = @import("std");

const lmdb = @import("lmdb");
const Key = @import("Key.zig");

pub fn Node(comptime K: u32, comptime Q: u8) type {
    return struct {
        const Self = @This();

        level: u8,
        key: ?[]const u8,
        hash: *const [K]u8,
        value: ?[]const u8 = null,

        pub inline fn isBoundary(self: Self) bool {
            const limit: comptime_int = (1 << 32) / @as(u33, @intCast(Q));
            return std.mem.readInt(u32, self.hash[0..4], .big) < limit;
        }

        pub inline fn isAnchor(self: Self) bool {
            return self.key == null;
        }

        pub inline fn equal(self: Self, other: Self) bool {
            return self.level == other.level and
                Key.equal(self.key, other.key) and
                std.mem.eql(u8, self.hash, other.hash);
        }

        pub fn expectEqual(expected: ?Self, actual: ?Self) !void {
            if (actual) |actual_node| {
                if (expected) |expected_node| {
                    try std.testing.expectEqual(expected_node.level, actual_node.level);
                    try Key.expectEqual(expected_node.key, actual_node.key);
                    try std.testing.expectEqualSlices(u8, expected_node.hash, actual_node.hash);
                } else {
                    return error.UnexpectedNode;
                }
            } else {
                if (expected != null) {
                    return error.ExpectedNode;
                }
            }
        }

        pub fn parse(key: []const u8, value: []const u8) !Self {
            if (key.len == 0 or value.len < K) {
                return error.InvalidDatabase;
            }

            return .{
                .level = key[0],
                .key = if (key.len > 1) key[1..] else null,
                .hash = value[0..K],
                .value = if (key[0] == 0 and key.len > 1) value[K..] else null,
            };
        }

        // fn formatNode(node: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        //     const charset = "0123456789abcdef";

        //     var buf: [2]u8 = undefined;
        //     if (key) |bytes| {
        //         for (bytes) |c| {
        //             buf[0] = charset[c >> 4];
        //             buf[1] = charset[c & 15];
        //             try writer.writeAll(&buf);
        //         }
        //     } else {
        //         try writer.writeAll("null");
        //     }
        // }

        // pub fn fmt(node: Self) std.fmt.Formatter(formatNode) {
        //     return .{ .data = key };
        // }
    };
}
