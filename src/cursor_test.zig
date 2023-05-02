const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const K = 16;
const Q = 4;

const Tree = @import("tree.zig").Tree(K, Q);
const Transaction = @import("transaction.zig").Transaction(K, Q);
const Cursor = @import("cursor.zig").Cursor(K, Q);
const Node = @import("node.zig").Node(K, Q);

const utils = @import("utils.zig");

fn h(value: *const [32]u8) [16]u8 {
    var buffer: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

test "Cursor(a, b, c)" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");

    var tree = try Tree.open(allocator, path, .{});
    defer tree.close();

    var txn = try Transaction.open(allocator, &tree, .{ .mode = .ReadWrite });
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

    try Node.expectEqualNodes(.{
        .level = 2,
        .key = null,
        .hash = &h("2453a3811e50851b4fc0bb95e1415b07"),
    }, try cursor.goToRoot());
    try Node.expectEqualNodes(null, try cursor.goToNext(2));

    try Node.expectEqualNodes(.{
        .level = 1,
        .key = null,
        .hash = &h("6c5483c477697c881f6b03dc23a52c7f"),
    }, try cursor.goToNode(1, null));

    try if (try cursor.goToNext(1)) |node| {
        try Node.expectEqualNodes(.{
            .level = 1,
            .key = "a",
            .hash = &h("d139f1b3444bc84fd46cbd56f7fe2fb5"),
        }, node);
    } else error.NotFound;

    try expectEqual(@as(?Node, null), try cursor.goToNext(1));

    // try txn.set("x", "hello world"); // a4fefb21af5e42531ed2b7860cf6e80a
    // try txn.set("z", "lorem ipsum"); // 4d41c77b6d7d709e7dd9803e07060681

    // try if (try cursor.seek(0, "y")) |node| {
    //     try expectEqualNode(0, "z", "4d41c77b6d7d709e7dd9803e07060681", "lorem ipsum", node);
    // } else error.NotFound;

    // try if (try cursor.goToPrevious()) |node| {
    //     try expectEqualNode(0, "x", "a4fefb21af5e42531ed2b7860cf6e80a", "hello world", node);
    // } else error.NotFound;

    // try if (try cursor.seek(0, null)) |node| {
    //     try expectEqualNode(0, null, "af1349b9f5f9a1a6a0404dea36dcc949", null, node);
    // } else error.NotFound;

    // try expectEqual(@as(?Node, null), try cursor.goToPrevious());
}
