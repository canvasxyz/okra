const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");

const K = 16;
const Q = 4;

const Iterator = @import("Iterator.zig").Iterator(K, Q);
const Node = @import("Node.zig").Node(K, Q);
const Store = @import("Store.zig").Store(K, Q);

const utils = @import("utils.zig");

fn h(value: *const [32]u8) [16]u8 {
    var buffer: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

test "Iterator(a, b, c)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try utils.open(tmp.dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    defer txn.abort();

    const db = try txn.database(null, .{});

    var store = try Store.init(allocator, db, .{});
    defer store.deinit();

    try store.set("a", "foo");
    try store.set("b", "bar");
    try store.set("c", "baz");

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

    var iter = try Iterator.init(allocator, db, .{ .level = 2 });
    defer iter.deinit();

    try Node.expectEqual(.{
        .level = 2,
        .key = null,
        .hash = &h("2453a3811e50851b4fc0bb95e1415b07"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{ .level = 1 });
    try Node.expectEqual(.{
        .level = 1,
        .key = null,
        .hash = &h("6c5483c477697c881f6b03dc23a52c7f"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 1,
        .key = "a",
        .hash = &h("d139f1b3444bc84fd46cbd56f7fe2fb5"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{ .level = 0 });
    try Node.expectEqual(.{
        .level = 0,
        .key = null,
        .hash = &h("af1349b9f5f9a1a6a0404dea36dcc949"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 0,
        .key = "a",
        .hash = &h("2f26b85f65eb9f7a8ac11e79e710148d"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 0,
        .key = "b",
        .hash = &h("684f1047a178e6cf9fff759ba1edec2d"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 0,
        .key = "c",
        .hash = &h("56cb13c78823525b08d471b6c1201360"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{ .level = 3 });
    try Node.expectEqual(null, try iter.next());
    try Node.expectEqual(null, try iter.next());

    // now test bounds

    try iter.reset(.{ .level = 1, .lower_bound = .{ .key = null, .inclusive = false } });
    try Node.expectEqual(.{
        .level = 1,
        .key = "a",
        .hash = &h("d139f1b3444bc84fd46cbd56f7fe2fb5"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = false },
        .upper_bound = .{ .key = "c", .inclusive = false },
    });
    try Node.expectEqual(.{
        .level = 0,
        .key = "b",
        .hash = &h("684f1047a178e6cf9fff759ba1edec2d"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = false },
        .upper_bound = .{ .key = "c", .inclusive = true },
    });
    try Node.expectEqual(.{
        .level = 0,
        .key = "b",
        .hash = &h("684f1047a178e6cf9fff759ba1edec2d"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 0,
        .key = "c",
        .hash = &h("56cb13c78823525b08d471b6c1201360"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = true },
        .upper_bound = .{ .key = "a", .inclusive = true },
    });
    try Node.expectEqual(.{
        .level = 0,
        .key = "a",
        .hash = &h("2f26b85f65eb9f7a8ac11e79e710148d"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{
        .level = 0,
        .upper_bound = .{ .key = "b", .inclusive = false },
        .reverse = true,
    });
    try Node.expectEqual(.{
        .level = 0,
        .key = "a",
        .hash = &h("2f26b85f65eb9f7a8ac11e79e710148d"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 0,
        .key = null,
        .hash = &h("af1349b9f5f9a1a6a0404dea36dcc949"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = true },
        .upper_bound = .{ .key = "a", .inclusive = true },
        .reverse = true,
    });
    try Node.expectEqual(.{
        .level = 0,
        .key = "a",
        .hash = &h("2f26b85f65eb9f7a8ac11e79e710148d"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = true },
        .upper_bound = .{ .key = "a", .inclusive = false },
        .reverse = true,
    });
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{
        .level = 0,
        .lower_bound = .{ .key = "a", .inclusive = false },
        .upper_bound = .{ .key = "a", .inclusive = true },
        .reverse = true,
    });
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{
        .level = 1,
        .reverse = true,
    });
    try Node.expectEqual(.{
        .level = 1,
        .key = "a",
        .hash = &h("d139f1b3444bc84fd46cbd56f7fe2fb5"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 1,
        .key = null,
        .hash = &h("6c5483c477697c881f6b03dc23a52c7f"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{
        .level = 1,
        .lower_bound = .{ .key = null, .inclusive = false },
        .reverse = true,
    });
    try Node.expectEqual(.{
        .level = 1,
        .key = "a",
        .hash = &h("d139f1b3444bc84fd46cbd56f7fe2fb5"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());
}
