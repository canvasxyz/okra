const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");

const K = 16;
const Q = 4;

const Iterator = @import("iterator.zig").Iterator(K, Q);
const Node = @import("node.zig").Node(K, Q);
const Tree = @import("tree.zig").Tree(K, Q);

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

    var tree = try Tree.init(allocator, db, .{});
    defer tree.deinit();

    try tree.set("a", "\x00");
    try tree.set("b", "\x01");
    try tree.set("c", "\x02");

    // okay here we expect
    // L0 -----------------------------
    // e3b0c44298fc1c149afbf4c8996fb924
    // f39bd65e0288b1f54b1f9d0aed568987 "a"
    // 89902f000cf47c6c01c66da838aadb70 "b"
    // 0bcff62fc85f03c136c9cb7fbd358216 "c"
    // L1 -----------------------------
    // c690df2a79dd4867260d5812d3abd9b4
    // fbe9d2ee084505176765652f9191c5ee "c"
    // L2 -----------------------------
    // a1d0d977083450f6935a1465e503da22

    var iter = try Iterator.init(allocator, db, .{ .level = 2 });
    defer iter.deinit();

    try Node.expectEqual(.{
        .level = 2,
        .key = null,
        .hash = &h("a1d0d977083450f6935a1465e503da22"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{ .level = 1 });
    try Node.expectEqual(.{
        .level = 1,
        .key = null,
        .hash = &h("c690df2a79dd4867260d5812d3abd9b4"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 1,
        .key = "c",
        .hash = &h("fbe9d2ee084505176765652f9191c5ee"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{ .level = 0 });
    try Node.expectEqual(.{
        .level = 0,
        .key = null,
        .hash = &h("e3b0c44298fc1c149afbf4c8996fb924"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 0,
        .key = "a",
        .hash = &h("f39bd65e0288b1f54b1f9d0aed568987"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 0,
        .key = "b",
        .hash = &h("89902f000cf47c6c01c66da838aadb70"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 0,
        .key = "c",
        .hash = &h("0bcff62fc85f03c136c9cb7fbd358216"),
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
        .key = "c",
        .hash = &h("fbe9d2ee084505176765652f9191c5ee"),
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
        .hash = &h("89902f000cf47c6c01c66da838aadb70"),
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
        .hash = &h("89902f000cf47c6c01c66da838aadb70"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 0,
        .key = "c",
        .hash = &h("0bcff62fc85f03c136c9cb7fbd358216"),
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
        .hash = &h("f39bd65e0288b1f54b1f9d0aed568987"),
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
        .hash = &h("f39bd65e0288b1f54b1f9d0aed568987"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 0,
        .key = null,
        .hash = &h("e3b0c44298fc1c149afbf4c8996fb924"),
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
        .hash = &h("f39bd65e0288b1f54b1f9d0aed568987"),
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
        .key = "c",
        .hash = &h("fbe9d2ee084505176765652f9191c5ee"),
    }, try iter.next());
    try Node.expectEqual(.{
        .level = 1,
        .key = null,
        .hash = &h("c690df2a79dd4867260d5812d3abd9b4"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());

    try iter.reset(.{
        .level = 1,
        .lower_bound = .{ .key = null, .inclusive = false },
        .reverse = true,
    });
    try Node.expectEqual(.{
        .level = 1,
        .key = "c",
        .hash = &h("fbe9d2ee084505176765652f9191c5ee"),
    }, try iter.next());
    try Node.expectEqual(null, try iter.next());
}
