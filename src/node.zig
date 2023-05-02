const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");
const utils = @import("utils.zig");
const expectEqualKeys = utils.expectEqualKeys;

pub fn Node(comptime K: u32, comptime Q: u8) type {
    return struct {
        const Self = @This();

        level: u8,
        key: ?[]const u8,
        hash: *const [K]u8,
        value: ?[]const u8 = null,

        pub inline fn isBoundary(self: Self) bool {
            return Self.isBoundaryHash(self.hash);
        }

        pub inline fn isBoundaryHash(hash: *const [K]u8) bool {
            const limit: comptime_int = (1 << 32) / @intCast(u33, Q);
            return std.mem.readIntBig(u32, hash[0..4]) < limit;
        }

        pub inline fn equal(self: Self, other: Self) bool {
            return self.level == other.level and
                utils.equal(self.key, other.key) and
                std.mem.eql(u8, self.hash, other.hash);
        }

        pub fn expectEqualNodes(actual: ?Self, expected: ?Self) !void {
            if (actual) |actual_node| {
                if (expected) |expected_node| {
                    try expectEqual(actual_node.level, expected_node.level);
                    try expectEqualKeys(actual_node.key, expected_node.key);
                    try expectEqualSlices(u8, actual_node.hash, expected_node.hash);
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
            if (key.len == 0) {
                return error.InvalidDatabase;
            }

            if (value.len < K) {
                return error.InvalidDatabase;
            }

            return .{
                .level = key[0],
                .key = if (key.len > 1) key[1..] else null,
                .hash = value[0..K],
                .value = if (key[0] == 0 and key.len > 1) value[K..] else null,
            };
        }
    };
}
