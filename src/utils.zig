const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const Blake3 = std.crypto.hash.Blake3;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");

pub fn printEntries(env: lmdb.Environment, writer: std.fs.File.Writer) !void {
    const txn = try lmdb.Transaction.open(env, .{ .read_only = true });
    defer txn.abort();

    const cursor = try lmdb.Cursor.open(txn);
    var entry = try cursor.goToFirst();
    while (entry) |key| : (entry = try cursor.goToNext()) {
        const value = try cursor.getCurrentValue();
        try writer.print("{s}\t{s}\n", .{ hex(key), hex(value) });
    }
}

pub fn hashEntry(key: []const u8, value: []const u8, result: []u8) void {
    var digest = Blake3.init(.{});
    var size: [4]u8 = undefined;
    std.mem.writeIntBig(u32, &size, @as(u32, @intCast(key.len)));
    digest.update(&size);
    digest.update(key);
    std.mem.writeIntBig(u32, &size, @as(u32, @intCast(value.len)));
    digest.update(&size);
    digest.update(value);
    digest.final(result);
}

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

test "key equality" {
    try expectEqual(equal("a", "a"), true);
    try expectEqual(equal("a", "b"), false);
    try expectEqual(equal("b", "a"), false);
    try expectEqual(equal(null, "a"), false);
    try expectEqual(equal("a", null), false);
    try expectEqual(equal(null, null), true);
}

fn formatKey(key: ?[]const u8, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    const charset = "0123456789abcdef";

    _ = fmt;
    _ = options;
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

pub fn fmtKey(key: ?[]const u8) std.fmt.Formatter(formatKey) {
    return .{ .data = key };
}

pub fn expectEqualKeys(actual: ?[]const u8, expected: ?[]const u8) !void {
    if (actual) |actual_bytes| {
        if (expected) |expected_bytes| {
            try expectEqualSlices(u8, actual_bytes, expected_bytes);
        } else {
            return error.TestExpectedEqualKeys;
        }
    } else if (expected != null) {
        return error.TestExpectedEqualKeys;
    }
}
