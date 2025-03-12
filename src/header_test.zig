const std = @import("std");
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");

const K = 32;
const Q = 4;
const Header = @import("Header.zig").Header(K, Q);

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

    const env = try utils.open(tmp.dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    defer txn.abort();

    const db = try txn.database(null, .{});

    try Header.write(db);

    try utils.expectEqualEntries(db, &.{
        .{ &[_]u8{0x00}, &empty_hash },
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 2, 32, 0, 0, 0, 4 } },
    });
}

test "initialize a header in named databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try utils.open(tmp.dir, .{ .max_dbs = 2 });
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    defer txn.abort();

    const db_a = try txn.database("a", .{ .create = true });
    const db_b = try txn.database("b", .{ .create = true });

    try Header.write(db_a);
    try Header.write(db_b);

    try if (try db_a.get(&[_]u8{0x00})) |value| expectEqualSlices(u8, &empty_hash, value) else error.KeyNotFound;
    try if (try db_a.get(&[_]u8{0xFF})) |value| expectEqualSlices(u8, &[_]u8{ 'o', 'k', 'r', 'a', 2, 32, 0, 0, 0, 4 }, value) else error.KeyNotFound;

    try if (try db_b.get(&[_]u8{0x00})) |value| expectEqualSlices(u8, &empty_hash, value) else error.KeyNotFound;
    try if (try db_b.get(&[_]u8{0xFF})) |value| expectEqualSlices(u8, &[_]u8{ 'o', 'k', 'r', 'a', 2, 32, 0, 0, 0, 4 }, value) else error.KeyNotFound;
}
