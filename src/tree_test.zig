const std = @import("std");

const lmdb = @import("lmdb");
const K = 32;
const Q = 4;

const Tree = @import("tree.zig").Tree(K, Q);

const utils = @import("utils.zig");

fn h(value: *const [64]u8) [32]u8 {
    var buffer: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

test "Tree.open()" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    var tree = try Tree.open(allocator, path, .{});
    defer tree.close();

    try lmdb.expectEqualEntries(tree.env, &.{
        .{ &[_]u8{0}, &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
    });
}

// test "Tree.print()" {
//     const allocator = std.heap.c_allocator;

//     var tmp = std.testing.tmpDir(.{});
//     defer tmp.cleanup();

//     const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
//     defer allocator.free(path);

//     const tree = try Tree.open(allocator, path, .{});
//     defer tree.close();

//     var keys: [10][2]u8 = undefined;
//     var value_buffer: [32]u8 = undefined;

//     {
//         const txn = try Transaction.open(allocator, tree, .{ .read_only = false });
//         errdefer txn.abort();

//         for (&keys) |*key, i| {
//             std.mem.writeIntBig(u16, key, @intCast(u16, i));
//             std.crypto.hash.sha2.Sha256.hash(key, &value_buffer, .{});
//             try txn.set(key, &value_buffer);
//         }

//         try txn.commit();
//     }

//     const log = std.io.getStdErr().writer();
//     try log.print("\n", .{});

//     try tree.print(log);
// }
