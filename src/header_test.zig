const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const expectEqualSlices = std.testing.expectEqualSlices;

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

const empty_hash = h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262");

test "initialize header in default database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");
    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    try Header.initialize(env, null);

    try lmdb.expectEqualEntries(env, &.{
        .{ &[_]u8{0x00}, &empty_hash },
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
    });
}

test "initialize header in named databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");
    const env = try lmdb.Environment.open(path, .{ .max_dbs = 2 });
    defer env.close();

    try Header.initialize(env, "a");
    try Header.initialize(env, "b");

    {
        const txn = try lmdb.Transaction.open(env, .{ .read_only = true, .dbi = "a" });
        defer txn.abort();
        try if (try txn.get(&[_]u8{0x00})) |value| expectEqualSlices(u8, &empty_hash, value) else error.KeyNotFound;
        try if (try txn.get(&[_]u8{0xFF})) |value| expectEqualSlices(u8, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 }, value) else error.KeyNotFound;
    }

    {
        const txn = try lmdb.Transaction.open(env, .{ .read_only = true, .dbi = "b" });
        defer txn.abort();
        try if (try txn.get(&[_]u8{0x00})) |value| expectEqualSlices(u8, &empty_hash, value) else error.KeyNotFound;
        try if (try txn.get(&[_]u8{0xFF})) |value| expectEqualSlices(u8, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 }, value) else error.KeyNotFound;
    }
}
