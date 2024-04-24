const std = @import("std");

pub fn lessThan(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |a_bytes| {
        if (b) |b_byte| {
            return std.mem.lessThan(u8, a_bytes, b_byte);
        } else {
            return false;
        }
    } else {
        return b != null;
    }
}

pub fn equal(a: ?[]const u8, b: ?[]const u8) bool {
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

pub fn expectEqual(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |actual_bytes| {
        if (actual) |expected_bytes| {
            try std.testing.expectEqualSlices(u8, actual_bytes, expected_bytes);
        } else {
            return error.TestExpectedEqualKeys;
        }
    } else if (actual != null) {
        return error.TestExpectedEqualKeys;
    }
}

test "key equality" {
    try std.testing.expectEqual(equal("a", "a"), true);
    try std.testing.expectEqual(equal("a", "b"), false);
    try std.testing.expectEqual(equal("b", "a"), false);
    try std.testing.expectEqual(equal(null, "a"), false);
    try std.testing.expectEqual(equal("a", null), false);
    try std.testing.expectEqual(equal(null, null), true);
}

fn formatKey(key: ?[]const u8, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    const charset = "0123456789abcdef";

    var buf: [2]u8 = undefined;
    if (key) |bytes| {
        for (bytes) |c| {
            buf[0] = charset[c >> 4];
            buf[1] = charset[c & 15];
            try writer.writeAll(&buf);
        }
    } else {
        try writer.writeAll("null");
    }
}

pub fn fmt(key: ?[]const u8) std.fmt.Formatter(formatKey) {
    return .{ .data = key };
}
