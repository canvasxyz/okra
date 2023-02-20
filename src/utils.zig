const std = @import("std");
const expectEqual = std.testing.expectEqual;
const Blake3 = std.crypto.hash.Blake3;

pub fn hashEntry(key: []const u8, value: []const u8, result: []u8) void {
    var digest = Blake3.init(.{});
    var size: [4]u8 = undefined;
    std.mem.writeIntBig(u32, &size, @intCast(u32, key.len));
    digest.update(&size);
    digest.update(key);
    std.mem.writeIntBig(u32, &size, @intCast(u32, value.len));
    digest.update(&size);
    digest.update(value);
    digest.final(result);
}

var path_buffer: [4096]u8 = undefined;
pub fn resolvePath(dir: std.fs.Dir, name: []const u8) ![*:0]const u8 {
    const path = try dir.realpath(name, &path_buffer);
    path_buffer[path.len] = 0;
    return @ptrCast([*:0]const u8, path_buffer[0..path.len]);
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

fn formatKey(
    key: ?[]const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
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

// fn formatSliceHexImpl(comptime case: Case) type {
//     const charset = "0123456789" ++ if (case == .upper) "ABCDEF" else "abcdef";

//     return struct {
//         pub fn formatSliceHexImpl(
//             bytes: []const u8,
//             comptime fmt: []const u8,
//             options: std.fmt.FormatOptions,
//             writer: anytype,
//         ) !void {
//             _ = fmt;
//             _ = options;
//             var buf: [2]u8 = undefined;

//             for (bytes) |c| {
//                 buf[0] = charset[c >> 4];
//                 buf[1] = charset[c & 15];
//                 try writer.writeAll(&buf);
//             }
//         }
//     };
// }

// const formatSliceHexLower = formatSliceHexImpl(.lower).formatSliceHexImpl;
// const formatSliceHexUpper = formatSliceHexImpl(.upper).formatSliceHexImpl;

// /// Return a Formatter for a []const u8 where every byte is formatted as a pair
// /// of lowercase hexadecimal digits.
// pub fn fmtSliceHexLower(bytes: []const u8) std.fmt.Formatter(formatSliceHexLower) {
//     return .{ .data = bytes };
// }
