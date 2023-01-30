const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const utils = @import("utils.zig");

const K = 16;
const Q = 4;
const Tree = @import("tree.zig").Tree(K, Q);
const Transaction = @import("transaction.zig").Transaction(K, Q);
const Cursor = @import("cursor.zig").Cursor(K, Q);
const Node = @import("node.zig").Node(K, Q);

fn h(value: *const [32]u8) [16]u8 {
    var buffer: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

fn expectEqualKeys(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected == null) {
        try expectEqual(expected, actual);
    } else {
        try expect(actual != null);
        try expectEqualSlices(u8, expected.?, actual.?);
    }
}

fn expectEqualNode(level: u8, key: ?[]const u8, hash: *const [32]u8, value: ?[]const u8, node: Node) !void {
    try expectEqual(level, node.level);
    try expectEqualKeys(key, node.key);
    try expectEqualSlices(u8, &h(hash), node.hash);
    try expectEqualKeys(value, node.value);
}

test "Cursor(a, b, c)" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    var tree = try Tree.open(allocator, path, .{});
    defer tree.close();

    var txn = try Transaction.open(allocator, &tree, .{ .read_only = false });
    defer txn.abort();

    try txn.set("a", "foo");
    try txn.set("b", "bar");
    try txn.set("c", "baz");

    // okay here we expect
    // L0 -----------------------------
    // af1349b9f5f9a1a6a0404dea36dcc949
    // 2f26b85f65eb9f7a8ac11e79e710148d "a"
    // 684f1047a178e6cf9fff759ba1edec2d "b"
    // 56cb13c78823525b08d471b6c1201360 "c"
    // L1 -----------------------------
    // 6c5483c477697c881f6b03dc23a52c7f
    // d139f1b3444bc84fd46cbd56f7fe2fb5 "a"
    // L2 -----------------------------
    // 2453a3811e50851b4fc0bb95e1415b07

    var cursor = try Cursor.open(allocator, &txn);
    defer cursor.close();

    const root = try cursor.goToRoot();
    try expectEqualNode(2, null, "2453a3811e50851b4fc0bb95e1415b07", null, root);
    try expectEqual(@as(?Node, null), try cursor.goToNext());

    {
        const node = try cursor.goToNode(1, null);
        try expectEqualNode(1, null, "6c5483c477697c881f6b03dc23a52c7f", null, node);
    }

    try if (try cursor.goToNext()) |node| {
        try expectEqualNode(1, "a", "d139f1b3444bc84fd46cbd56f7fe2fb5", null, node);
    } else error.NotFound;

    try expectEqual(@as(?Node, null), try cursor.goToNext());

    try txn.set("x", "hello world"); // a4fefb21af5e42531ed2b7860cf6e80a
    try txn.set("z", "lorem ipsum"); // 4d41c77b6d7d709e7dd9803e07060681

    try if (try cursor.seek(0, "y")) |node| {
        try expectEqualNode(0, "z", "4d41c77b6d7d709e7dd9803e07060681", "lorem ipsum", node);
    } else error.NotFound;

    try if (try cursor.goToPrevious()) |node| {
        try expectEqualNode(0, "x", "a4fefb21af5e42531ed2b7860cf6e80a", "hello world", node);
    } else error.NotFound;

    try if (try cursor.seek(0, null)) |node| {
        try expectEqualNode(0, null, "af1349b9f5f9a1a6a0404dea36dcc949", null, node);
    } else error.NotFound;

    try expectEqual(@as(?Node, null), try cursor.goToPrevious());
}
