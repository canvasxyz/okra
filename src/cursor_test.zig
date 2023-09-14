const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");

const K = 32;
const Q = 4;
const Header = @import("cursor.zig").Header(K, Q);
const Builder = @import("builder.zig").Builder(K, Q);
const Cursor = @import("cursor.zig").Cursor(K, Q);
const utils = @import("utils.zig");

const allocator = std.heap.c_allocator;

test "basic cursor operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try lmdb.utils.resolvePath(tmp.dir, ".");
    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadWrite });
    defer txn.abort();

    var builder = try Builder.open(allocator, .{ .txn = txn });
    defer builder.deinit();
    try builder.set("a", "foo");
    try builder.set("b", "bar");
    try builder.set("c", "baz");
    try builder.build();

    var cursor = try Cursor.open(allocator, txn, .{});
    const root = try cursor.goToRoot();
    try expect(root.level == 3);
    try expect(root.key == null);
    try expect(root.value == null);

    if (try cursor.seek(0, "a")) |node| {
        try expectEqual(node.level, 0);
        try utils.expectEqualKeys(node.key, "a");
        try utils.expectEqualKeys(node.value, "foo");
    } else return error.NotFound;

    if (try cursor.goToNext()) |node| {
        try expectEqual(node.level, 0);
        try utils.expectEqualKeys(node.key, "b");
        try utils.expectEqualKeys(node.value, "bar");
    } else return error.NotFound;

    if (try cursor.goToNext()) |node| {
        try expectEqual(node.level, 0);
        try utils.expectEqualKeys(node.key, "c");
        try utils.expectEqualKeys(node.value, "baz");
    } else return error.NotFound;
}
