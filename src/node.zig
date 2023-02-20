const std = @import("std");
const expectEqual = std.testing.expectEqual;

const lmdb = @import("lmdb");
const utils = @import("utils.zig");

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

        pub fn equal(self: Self, other: Self) bool {
            return self.level == other.level and
                utils.equal(self.key, other.key) and
                std.mem.eql(u8, self.hash, other.hash);
        }

        pub fn parse(entry: lmdb.Cursor.Entry) !Self {
            if (entry.key.len == 0) {
                return error.InvalidDatabase;
            }

            if (entry.value.len < K) {
                return error.InvalidDatabase;
            }

            const level = entry.key[0];
            const key = if (entry.key.len > 1) entry.key[1..] else null;
            const hash = entry.value[0..K];
            const value = if (level == 0 and key != null) entry.value[K..] else null;
            return .{ .level = level, .key = key, .hash = hash, .value = value };
        }
    };
}
