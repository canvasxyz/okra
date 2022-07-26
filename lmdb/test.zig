const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Environment = @import("environment.zig").Environment;
const Transaction = @import("transaction.zig").Transaction;
const Cursor = @import("cursor.zig").Cursor;

const compareEntries = @import("compare.zig").compareEntries;

const allocator = std.heap.c_allocator;

test "compareEntries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &buffer);

    const path_a = try std.fs.path.joinZ(allocator, &.{ tmp_path, "a.mdb" });
    defer allocator.free(path_a);
    const path_b = try std.fs.path.joinZ(allocator, &.{ tmp_path, "b.mdb" });
    defer allocator.free(path_b);

    const env_a = try Environment.open(path_a, .{});
    defer env_a.close();

    {
        const txn_a = try Transaction.open(env_a, .{ .read_only = false });
        errdefer txn_a.abort();
        try txn_a.set("x", "foo");
        try txn_a.set("y", "bar");
        try txn_a.set("z", "baz");
        try txn_a.commit();
    }

    const env_b = try Environment.open(path_b, .{});
    defer env_b.close();

    {
        const txn_b = try Transaction.open(env_b, .{ .read_only = false });
        errdefer txn_b.abort();
        try txn_b.set("y", "bar");
        try txn_b.set("z", "qux");
        try txn_b.commit();
    }

    try expectEqual(try compareEntries(env_a, env_b, .{}), 2);
    try expectEqual(try compareEntries(env_b, env_a, .{}), 2);

    {
        const txn_c = try Transaction.open(env_b, .{ .read_only = false });
        errdefer txn_c.abort();
        try txn_c.set("x", "foo");
        try txn_c.set("z", "baz");
        try txn_c.commit();
    }

    try expectEqual(try compareEntries(env_a, env_b, .{}), 0);
    try expectEqual(try compareEntries(env_b, env_a, .{}), 0);
}

test "set empty value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var tmp_path = try tmp.dir.realpath(".", &buffer);

    var path = try std.fs.path.joinZ(allocator, &.{ tmp_path, "data.mdb" });
    defer allocator.free(path);

    const env = try Environment.open(path, .{});
    defer env.close();

    const txn = try Transaction.open(env, .{ .read_only = false });
    defer txn.abort();

    try txn.set("a", "");
    if (try txn.get("a")) |value| {
        try expect(value.len == 0);
    } else {
        return error.KeyNotFound;
    }
}

test "delete while iterating" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var tmp_path = try tmp.dir.realpath(".", &buffer);

    var path = try std.fs.path.joinZ(allocator, &.{ tmp_path, "data.mdb" });
    defer allocator.free(path);

    const env = try Environment.open(path, .{});
    defer env.close();

    const txn = try Transaction.open(env, .{ .read_only = false });
    defer txn.abort();

    try txn.set("a", "foo");
    try txn.set("b", "bar");
    try txn.set("c", "baz");
    try txn.set("d", "qux");

    const cursor = try Cursor.open(txn);
    try cursor.goToKey("c");
    try expectEqualSlices(u8, try cursor.getCurrentValue(), "baz");
    try txn.delete("c");
    try expect(try cursor.goToPrevious() != null);
    try expectEqualSlices(u8, try cursor.getCurrentKey(), "b");
    try expectEqualSlices(u8, try cursor.getCurrentValue(), "bar");
}

test "seek" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var tmp_path = try tmp.dir.realpath(".", &buffer);

    var path = try std.fs.path.joinZ(allocator, &.{ tmp_path, "data.mdb" });
    defer allocator.free(path);

    const env = try Environment.open(path, .{});
    defer env.close();

    const txn = try Transaction.open(env, .{ .read_only = false });
    defer txn.abort();

    try txn.set("a", "foo");
    try txn.set("aa", "bar");
    try txn.set("ab", "baz");
    try txn.set("abb", "qux");

    const cursor = try Cursor.open(txn);
    try expectEqualSlices(u8, (try cursor.seek("aba")).?, "abb");
    try expect(try cursor.seek("b") == null);
}

// test "parent transactions" {
//     var tmp = std.testing.tmpDir(.{});
//     defer tmp.cleanup();

//     var buffer: [4096]u8 = undefined;
//     var tmp_path = try tmp.dir.realpath(".", &buffer);

//     var path = try std.fs.path.joinZ(allocator, &.{ tmp_path, "data.mdb" });
//     defer allocator.free(path);

//     const env = try Environment.open(path, .{});
//     defer env.close();

//     {
//         const txn_a = try Transaction.open(env, .{ .read_only = false });
//         errdefer txn_a.abort();

//         try txn_a.set("a", "foo");
//         try txn_a.set("b", "bar");

//         {
//             const txn_b = try Transaction.open(env, .{ .read_only = false, .parent = txn_a });
//             defer txn_b.abort();
//             try txn_b.set("c", "bax");
//             try txn_b.set("d", "qux");
//         }

//         {
//             const txn_c = try Transaction.open(env, .{ .read_only = false, .parent = txn_a });
//             errdefer txn_c.abort();
//             try txn_c.set("e", "wau");
//             try txn_c.set("f", "ooo");
//             try txn_c.commit();
//         }

//         try txn_a.commit();
//     }

//     const txn = try Transaction.open(env, .{ .read_only = true });
//     defer txn.abort();
//     try expectEqualSlices(u8, "foo", try txn.get("a") orelse return error.KeyNotFound);
//     try expectEqualSlices(u8, "bar", try txn.get("b") orelse return error.KeyNotFound);
//     try expectEqualSlices(u8, "wow", try txn.get("e") orelse return error.KeyNotFound);
//     try expectEqualSlices(u8, "ooo", try txn.get("f") orelse return error.KeyNotFound);
// }
