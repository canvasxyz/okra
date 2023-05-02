const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const K = 16;
const Q = 4;

const Tree = @import("tree.zig").Tree(K, Q);
const Transaction = @import("transaction.zig").Transaction(K, Q);
const Iterator = @import("iterator.zig").Iterator(K, Q);
const Node = @import("node.zig").Node(K, Q);

const utils = @import("utils.zig");

fn h(value: *const [32]u8) [16]u8 {
    var buffer: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

test "Iterator(a, b, c)" {
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

    var iterator = try Iterator.open(allocator, &txn, .{ .level = 2 });
    defer iterator.close();

    try Node.expectEqualNodes(.{
        .level = 2,
        .key = null,
        .hash = &h("2453a3811e50851b4fc0bb95e1415b07"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{ .level = 1 });
    try Node.expectEqualNodes(.{
        .level = 1,
        .key = null,
        .hash = &h("6c5483c477697c881f6b03dc23a52c7f"),
    }, try iterator.next());
    try Node.expectEqualNodes(.{
        .level = 1,
        .key = "a",
        .hash = &h("d139f1b3444bc84fd46cbd56f7fe2fb5"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{ .level = 0 });
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = null,
        .hash = &h("af1349b9f5f9a1a6a0404dea36dcc949"),
    }, try iterator.next());
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = "a",
        .hash = &h("2f26b85f65eb9f7a8ac11e79e710148d"),
    }, try iterator.next());
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = "b",
        .hash = &h("684f1047a178e6cf9fff759ba1edec2d"),
    }, try iterator.next());
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = "c",
        .hash = &h("56cb13c78823525b08d471b6c1201360"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{ .level = 3 });
    try Node.expectEqualNodes(null, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    // now test bounds

    try iterator.reset(.{ .level = 1, .lower_bound = .{ .key = null, .inclusive = false } });
    try Node.expectEqualNodes(.{
        .level = 1,
        .key = "a",
        .hash = &h("d139f1b3444bc84fd46cbd56f7fe2fb5"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = false },
        .upper_bound = .{ .key = "c", .inclusive = false },
    });
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = "b",
        .hash = &h("684f1047a178e6cf9fff759ba1edec2d"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = false },
        .upper_bound = .{ .key = "c", .inclusive = true },
    });
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = "b",
        .hash = &h("684f1047a178e6cf9fff759ba1edec2d"),
    }, try iterator.next());
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = "c",
        .hash = &h("56cb13c78823525b08d471b6c1201360"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = true },
        .upper_bound = .{ .key = "a", .inclusive = true },
    });
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = "a",
        .hash = &h("2f26b85f65eb9f7a8ac11e79e710148d"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{
        .level = 0,
        .upper_bound = .{ .key = "b", .inclusive = false },
        .reverse = true,
    });
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = "a",
        .hash = &h("2f26b85f65eb9f7a8ac11e79e710148d"),
    }, try iterator.next());
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = null,
        .hash = &h("af1349b9f5f9a1a6a0404dea36dcc949"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = true },
        .upper_bound = .{ .key = "a", .inclusive = true },
        .reverse = true,
    });
    try Node.expectEqualNodes(.{
        .level = 0,
        .key = "a",
        .hash = &h("2f26b85f65eb9f7a8ac11e79e710148d"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = true },
        .upper_bound = .{ .key = "a", .inclusive = false },
        .reverse = true,
    });
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = false },
        .upper_bound = .{ .key = "a", .inclusive = true },
        .reverse = true,
    });
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{
        .level = 1,
        .reverse = true,
    });
    try Node.expectEqualNodes(.{
        .level = 1,
        .key = "a",
        .hash = &h("d139f1b3444bc84fd46cbd56f7fe2fb5"),
    }, try iterator.next());
    try Node.expectEqualNodes(.{
        .level = 1,
        .key = null,
        .hash = &h("6c5483c477697c881f6b03dc23a52c7f"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());

    try iterator.reset(.{
        .level = 1,
        .lower_bound = .{ .key = null, .inclusive = false },
        .reverse = true,
    });
    try Node.expectEqualNodes(.{
        .level = 1,
        .key = "a",
        .hash = &h("d139f1b3444bc84fd46cbd56f7fe2fb5"),
    }, try iterator.next());
    try Node.expectEqualNodes(null, try iterator.next());
}
