const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const K = 32;
const Q = 4;
const Header = @import("header.zig").Header(K, Q);

const utils = @import("utils.zig");

fn h(comptime value: *const [64]u8) [32]u8 {
    var buffer: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

test "Header.initialize()" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    try Header.initialize(env);

    try lmdb.expectEqualEntries(env, &.{
        .{ &[_]u8{0x00}, &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
    });
}
