const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");

const K = 32;
const Q = 4;
const Header = @import("cursor.zig").Header(K, Q);
const Builder = @import("builder.zig").Builder(K, Q);
const Cursor = @import("cursor.zig").Cursor(K, Q);
const Key = @import("Key.zig");
const utils = @import("utils.zig");

const allocator = std.heap.c_allocator;

test "basic cursor operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try utils.open(tmp.dir, .{});
    defer env.deinit();

    const txn = try lmdb.Transaction.init(env, .{ .mode = .ReadWrite });
    defer txn.abort();

    const db = try txn.database(null, .{});

    var builder = try Builder.init(allocator, db, .{});
    defer builder.deinit();

    try builder.set("a", "\x00");
    try builder.set("b", "\x01");
    try builder.set("c", "\x02");
    try builder.build();

    var cursor = try Cursor.init(allocator, db);
    defer cursor.deinit();

    const root = try cursor.goToRoot();
    try expect(root.level == 2);
    try expect(root.key == null);
    try expect(root.value == null);

    if (try cursor.seek(0, "a")) |node| {
        try expectEqual(0, node.level);
        try Key.expectEqual("a", node.key);
        try Key.expectEqual("\x00", node.value);
    } else return error.NotFound;

    if (try cursor.goToNext()) |node| {
        try expectEqual(0, node.level);
        try Key.expectEqual("b", node.key);
        try Key.expectEqual("\x01", node.value);
    } else return error.NotFound;

    if (try cursor.goToNext()) |node| {
        try expectEqual(0, node.level);
        try Key.expectEqual("c", node.key);
        try Key.expectEqual("\x02", node.value);
    } else return error.NotFound;
}
