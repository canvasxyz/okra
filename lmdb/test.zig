const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Environment = @import("environment.zig").Environment;
const Transaction = @import("transaction.zig").Transaction;
const Cursor = @import("cursor.zig").Cursor;

const compareEntries = @import("compare.zig").compareEntries;
const utils = @import("utils.zig");

const allocator = std.heap.c_allocator;

test "multiple named databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");
    const env = try Environment.open(path, .{ .max_dbs = 2 });
    defer env.close();

    {
        const txn = try Transaction.open(env, .{ .read_only = false, .dbi = "a" });
        errdefer txn.abort();
        try txn.set("x", "foo");
        try txn.commit();
    }

    {
        const txn = try Transaction.open(env, .{ .read_only = false, .dbi = "b" });
        errdefer txn.abort();
        try txn.set("x", "bar");
        try txn.commit();
    }

    {
        const txn = try Transaction.open(env, .{ .read_only = true, .dbi = "a" });
        defer txn.abort();
        try utils.expectEqualKeys(try txn.get("x"), "foo");
    }

    {
        const txn = try Transaction.open(env, .{ .read_only = true, .dbi = "b" });
        defer txn.abort();
        try utils.expectEqualKeys(try txn.get("x"), "bar");
    }
}

test "compareEntries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("a");
    try tmp.dir.makeDir("b");

    const path_a = try utils.resolvePath(tmp.dir, "a");
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

    const path_b = try utils.resolvePath(tmp.dir, "b");
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

    const path = try utils.resolvePath(tmp.dir, ".");

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

test "stat" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");

    const env = try Environment.open(path, .{});
    defer env.close();

    {
        const txn = try Transaction.open(env, .{ .read_only = false });
        errdefer txn.abort();

        try txn.set("a", "foo");
        try txn.set("b", "bar");
        try txn.set("c", "baz");
        try txn.set("a", "aaa");

        try txn.commit();
    }

    try expectEqual(Environment.Stat{ .entries = 3 }, try env.stat());

    {
        const txn = try Transaction.open(env, .{ .read_only = false });
        errdefer txn.abort();
        try txn.delete("c");
        try txn.commit();
    }

    try expectEqual(Environment.Stat{ .entries = 2 }, try env.stat());
}

test "Cursor.deleteCurrentKey()" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");
    const env = try Environment.open(path, .{});
    defer env.close();

    {
        const txn = try Transaction.open(env, .{ .read_only = false });
        errdefer txn.abort();

        try txn.set("a", "foo");
        try txn.set("b", "bar");
        try txn.set("c", "baz");
        try txn.set("d", "qux");

        const cursor = try Cursor.open(txn);
        try cursor.goToKey("c");
        try expectEqualSlices(u8, try cursor.getCurrentValue(), "baz");
        try cursor.deleteCurrentKey();
        try expectEqualSlices(u8, try cursor.getCurrentKey(), "d");
        try utils.expectEqualKeys(try cursor.goToPrevious(), "b");

        try txn.commit();
    }

    try utils.expectEqualEntries(env, &.{
        .{ "a", "foo" },
        .{ "b", "bar" },
        .{ "d", "qux" },
    });
}

test "seek" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");
    const env = try Environment.open(path, .{});
    defer env.close();

    {
        const txn = try Transaction.open(env, .{ .read_only = false });
        errdefer txn.abort();

        try txn.set("a", "foo");
        try txn.set("aa", "bar");
        try txn.set("ab", "baz");
        try txn.set("abb", "qux");

        const cursor = try Cursor.open(txn);
        try utils.expectEqualKeys(try cursor.seek("aba"), "abb");
        try expectEqual(try cursor.seek("b"), null);

        try txn.commit();
    }

    try utils.expectEqualEntries(env, &.{
        .{ "a", "foo" },
        .{ "aa", "bar" },
        .{ "ab", "baz" },
        .{ "abb", "qux" },
    });
}
