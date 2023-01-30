const std = @import("std");
const expectEqual = std.testing.expectEqual;

pub fn Node(comptime K: u32, comptime Q: u8) type {
    return struct {
        const Self = @This();

        level: u8,
        key: ?[]const u8,
        hash: *const [K]u8,
        value: ?[]const u8,

        pub fn isSplit(self: Self) bool {
            const limit: comptime_int = (1 << 32) / @intCast(u33, Q);
            return std.mem.readIntBig(u32, self.hash[0..4]) < limit;
        }

        pub fn equalNodes(self: Self, other: Self) bool {
            return self.level == other.level and
                equalKeys(self.key, other.key) and
                std.mem.eql(u8, self.hash, other.hash);
        }

        pub fn equalKeys(a: ?[]const u8, b: ?[]const u8) bool {
            if (a) |a_bytes| {
                if (b) |b_bytes| {
                    return std.mem.eql(u8, a_bytes, b_bytes);
                } else {
                    return false;
                }
            } else {
                return b == null;
            }
        }

        test "equalKeys" {
            try expectEqual(equalKeys("a", "a"), true);
            try expectEqual(equalKeys("a", "b"), false);
            try expectEqual(equalKeys("b", "a"), false);
            try expectEqual(equalKeys(null, "a"), false);
            try expectEqual(equalKeys("a", null), false);
            try expectEqual(equalKeys(null, null), true);
        }
    };
}
