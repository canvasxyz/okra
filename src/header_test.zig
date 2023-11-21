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

test "initialize a header in default database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try lmdb.Environment.openDir(tmp.dir, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadWrite });
    defer txn.abort();

    const dbi = try txn.openDatabase(null, .{});

    try Header.write(txn, dbi);

    try lmdb.utils.expectEqualEntries(txn, dbi, &.{
        .{ &[_]u8{0x00}, &empty_hash },
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
    });
}

test "initialize a header in named databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try lmdb.Environment.openDir(tmp.dir, .{ .max_dbs = 2 });
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadWrite });
    defer txn.abort();

    const dbi_a = try txn.openDatabase("a", .{});
    const dbi_b = try txn.openDatabase("b", .{});

    try Header.write(txn, dbi_a);
    try Header.write(txn, dbi_b);

    try if (try txn.get(dbi_a, &[_]u8{0x00})) |value| expectEqualSlices(u8, &empty_hash, value) else error.KeyNotFound;
    try if (try txn.get(dbi_a, &[_]u8{0xFF})) |value| expectEqualSlices(u8, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 }, value) else error.KeyNotFound;

    try if (try txn.get(dbi_b, &[_]u8{0x00})) |value| expectEqualSlices(u8, &empty_hash, value) else error.KeyNotFound;
    try if (try txn.get(dbi_b, &[_]u8{0xFF})) |value| expectEqualSlices(u8, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 }, value) else error.KeyNotFound;
}
