const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Environment = @import("./environment.zig").Environment;
const Transaction = @import("./transaction.zig").Transaction;
const Cursor = @import("./cursor.zig").Cursor;

const compareEntries = @import("./compare.zig").compareEntries;

const allocator = std.heap.c_allocator;

test "compareEntries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var tmp_path = try tmp.dir.realpath(".", &buffer);

    var path_a = try std.fs.path.joinZ(allocator, &.{ tmp_path, "a.mdb" });
    defer allocator.free(path_a);
    var path_b = try std.fs.path.joinZ(allocator, &.{ tmp_path, "b.mdb" });
    defer allocator.free(path_b);

    var env_a = try Environment.open(path_a, .{});
    defer env_a.close();

    var txn_a = try Transaction.open(env_a, false);
    errdefer txn_a.abort();

    try txn_a.set("x", "foo");
    try txn_a.set("y", "bar");
    try txn_a.set("z", "baz");
    try txn_a.commit();

    var env_b = try Environment.open(path_b, .{});
    defer env_b.close();

    var txn_b = try Transaction.open(env_b, false);
    errdefer txn_b.abort();

    try txn_b.set("y", "bar");
    try txn_b.set("z", "qux");
    try txn_b.commit();

    try expectEqual(try compareEntries(env_a, env_b, .{}), 2);
    try expectEqual(try compareEntries(env_b, env_a, .{}), 2);

    txn_b = try Transaction.open(env_b, false);
    try txn_b.set("x", "foo");
    try txn_b.set("z", "baz");
    try txn_b.commit();

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
    
    var env = try Environment.open(path, .{});
    defer env.close();
    
    var txn = try Transaction.open(env, false);
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
    
    var env = try Environment.open(path, .{});
    defer env.close();
    
    var txn = try Transaction.open(env, false);
    defer txn.abort();
    
    try txn.set("a", "foo");
    try txn.set("b", "bar");
    try txn.set("c", "baz");
    try txn.set("d", "qux");
    
    var cursor = try Cursor.open(txn);
    try cursor.goToKey("c");
    try expectEqualSlices(u8, try cursor.getCurrentValue(), "baz");
    try txn.delete("c");
    try expect(try cursor.goToPrevious() != null);
    try expectEqualSlices(u8, try cursor.getCurrentKey(), "b");
    try expectEqualSlices(u8, try cursor.getCurrentValue(), "bar");
}
