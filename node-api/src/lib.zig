const std = @import("std");
const allocator = std.heap.c_allocator;

const okra = @import("okra");
const c = @import("./c.zig");
const n = @import("./n.zig");

const TreeTypeTag = c.napi_type_tag{
    .lower = 0x1B67FCDD82CD4514,
    .upper = 0xB2B9016A53BAF0F9,
};

const TransactionTypeTag = c.napi_type_tag{
    .lower = 0xF727CF6D5C254E54,
    .upper = 0xB5EDCA98B9F7AA6F,
};

const IteratorTypeTag = c.napi_type_tag{
    .lower = 0x6AEB370CA49B4E70,
    .upper = 0xB0BD8E22C5C8C8F1,
};

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.C) c.napi_value {
    // new Tree(path, options)
    {
        const treeMethods = [_]n.Method{
            comptime n.createMethod("close", 0, treeCloseMethod),
        };

        n.defineClass("Tree", 2, createTree, &treeMethods, env, exports) catch return null;
    }

    // new Transaction(tree, readOnly, dbi)
    {
        const transactionMethods = [_]n.Method{
            comptime n.createMethod("abort", 0, transactionAbortMethod),
            comptime n.createMethod("commit", 0, transactionCommitMethod),

            comptime n.createMethod("get", 1, transactionGetMethod),
            comptime n.createMethod("set", 2, transactionSetMethod),
            comptime n.createMethod("delete", 1, transactionDeleteMethod),

            comptime n.createMethod("getRoot", 0, transactionGetRootMethod),
            comptime n.createMethod("getNode", 2, transactionGetNodeMethod),
            comptime n.createMethod("getChildren", 2, transactionGetChildrenMethod),
        };

        n.defineClass("Transaction", 3, createTransaction, &transactionMethods, env, exports) catch return null;
    }

    // new Iterator(txn, level, lowerBound, upperBound, reverse)
    {
        const iteratorMethods = [_]n.Method{
            comptime n.createMethod("close", 0, iteratorCloseMethod),
            comptime n.createMethod("next", 0, iteratorNextMethod),
        };

        n.defineClass("Iterator", 5, createIterator, &iteratorMethods, env, exports) catch return null;
    }

    return exports;
}

// new Tree(path, options)

pub fn createTree(env: c.napi_env, this: c.napi_value, args: *const [2]c.napi_value) !c.napi_value {
    const pathArg = args[0];
    const optionsArg = args[1];

    const path = try n.parseStringAlloc(env, pathArg, allocator);
    defer allocator.free(path);

    var map_size: usize = 10485760;
    const map_size_property = try n.createString(env, "mapSize");
    const map_size_value = try n.getProperty(env, optionsArg, map_size_property);
    const map_size_value_type = try n.typeOf(env, map_size_value);
    if (map_size_value_type != c.napi_undefined) {
        map_size = try n.parseUint32(env, map_size_value);
    }

    var dbs = std.ArrayList([*:0]const u8).init(allocator);
    defer dbs.deinit();
    defer for (dbs.items) |dbi| allocator.free(std.mem.span(dbi));

    const dbs_property = try n.createString(env, "dbs");
    const dbs_value = try n.getProperty(env, optionsArg, dbs_property);
    const dbs_value_type = try n.typeOf(env, dbs_value);
    if (dbs_value_type != c.napi_undefined) {
        const length = try n.getLength(env, dbs_value);
        var i: u32 = 0;
        while (i < length) : (i += 1) {
            const dbi_value = try n.getElement(env, dbs_value, i);
            const dbi = try n.parseStringAlloc(env, dbi_value, allocator);
            try dbs.append(dbi);
        }
    }

    const tree = try allocator.create(okra.Tree);
    try tree.init(allocator, path, .{ .map_size = map_size, .dbs = if (dbs.items.len > 0) dbs.items else null });
    try n.wrap(okra.Tree, env, this, tree, destroyTree, &TreeTypeTag);

    return try n.getUndefined(env);
}

pub fn destroyTree(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const tree = @ptrCast(*okra.Tree, @alignCast(@alignOf(okra.Tree), ptr));
        allocator.destroy(tree);
    }
}

fn treeCloseMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const tree = try n.unwrap(okra.Tree, &TreeTypeTag, env, this);
    tree.close();
    return try n.getUndefined(env);
}

// new Transaction(tree, readOnly, dbi)

pub fn createTransaction(env: c.napi_env, this: c.napi_value, args: *const [3]c.napi_value) !c.napi_value {
    const tree = try n.unwrap(okra.Tree, &TreeTypeTag, env, args[0]);
    const mode: okra.Transaction.Mode = if (try n.parseBoolean(env, args[1])) .ReadOnly else .ReadWrite;
    const txn = try allocator.create(okra.Transaction);

    const dbi_type = try n.typeOf(env, args[2]);
    if (dbi_type == c.napi_null) {
        try txn.init(allocator, tree, .{ .mode = mode, .dbi = null });
    } else if (dbi_type == c.napi_string) {
        const dbi = try n.parseStringAlloc(env, args[2], allocator);
        defer allocator.free(dbi);
        try txn.init(allocator, tree, .{ .mode = mode, .dbi = dbi.ptr });
    } else {
        return n.throwError(env, "invalid dbi - expected string or null");
    }

    try n.wrap(okra.Transaction, env, this, txn, destroyTransaction, &TransactionTypeTag);

    return try n.getUndefined(env);
}

pub fn destroyTransaction(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const txn = @ptrCast(*okra.Transaction, @alignCast(@alignOf(okra.Transaction), ptr));
        if (txn.is_open) {
            txn.abort();
        }

        allocator.destroy(txn);
    }
}

fn transactionAbortMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);
    txn.abort();
    return try n.getUndefined(env);
}

fn transactionCommitMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);
    try txn.commit();
    return try n.getUndefined(env);
}

fn transactionGetMethod(env: c.napi_env, this: c.napi_value, args: *const [1]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);
    const key = try n.parseTypedArray(u8, env, args[0]);
    const value = try txn.get(key);
    if (value) |bytes| {
        return try n.createTypedArray(u8, env, bytes);
    } else {
        return try n.getNull(env);
    }
}

fn transactionSetMethod(env: c.napi_env, this: c.napi_value, args: *const [2]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);

    const key = try n.parseTypedArray(u8, env, args[0]);
    const value = try n.parseTypedArray(u8, env, args[1]);

    try txn.set(key, value);

    return try n.getUndefined(env);
}

fn transactionDeleteMethod(env: c.napi_env, this: c.napi_value, args: *const [1]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);

    const key = try n.parseTypedArray(u8, env, args[0]);

    try txn.delete(key);

    return try n.getUndefined(env);
}

fn transactionGetNodeMethod(env: c.napi_env, this: c.napi_value, args: *const [2]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);

    const level = try parseLevel(env, args[0]);
    const key = try parseKey(env, args[1]);

    const node = try txn.cursor.goToNode(level, key);

    return try createNode(env, node);
}

fn transactionGetRootMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);

    const root = try txn.cursor.goToRoot();

    return try createNode(env, root);
}

fn transactionGetChildrenMethod(env: c.napi_env, this: c.napi_value, args: *const [2]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);

    const level = try parseLevel(env, args[0]);
    const key = try parseKey(env, args[1]);

    if (level == 0) {
        return n.throwRangeError(env, "cannot get children of a leaf node");
    }

    var children = std.ArrayList(c.napi_value).init(allocator);
    defer children.deinit();

    const first_child = try txn.cursor.goToNode(level - 1, key);
    const first_child_node = try createNode(env, first_child);
    try children.append(first_child_node);

    while (try txn.cursor.goToNext()) |next_child| {
        if (next_child.isBoundary()) {
            break;
        } else {
            const next_child_node = try createNode(env, next_child);
            try children.append(next_child_node);
        }
    }

    return try n.wrapArray(env, children.items);
}

fn transactionSeekMethod(env: c.napi_env, this: c.napi_value, args: *const [2]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);

    const level = try parseLevel(env, args[0]);
    const key = try parseKey(env, args[1]);

    if (try txn.cursor.seek(level, key)) |node| {
        return try createNode(env, node);
    } else {
        return try n.getNull(env);
    }
}

// new Iterator(txn, level, lowerBound, upperBound, reverse)

pub fn createIterator(env: c.napi_env, this: c.napi_value, args: *const [5]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, args[0]);
    const iterator = try allocator.create(okra.Iterator);

    try iterator.init(allocator, txn, .{
        .level = try parseLevel(env, args[1]),
        .lower_bound = try parseBound(env, args[2]),
        .upper_bound = try parseBound(env, args[3]),
        .reverse = try n.parseBoolean(env, args[4]),
    });

    try n.wrap(okra.Iterator, env, this, iterator, destroyIterator, &IteratorTypeTag);

    return try n.getUndefined(env);
}

pub fn destroyIterator(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const iterator = @ptrCast(*okra.Iterator, @alignCast(@alignOf(okra.Iterator), ptr));
        iterator.close();
        allocator.destroy(iterator);
    }
}

fn iteratorCloseMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const iterator = try n.unwrap(okra.Iterator, &IteratorTypeTag, env, this);
    iterator.close();
    return try n.getUndefined(env);
}

fn iteratorNextMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const iterator = try n.unwrap(okra.Iterator, &IteratorTypeTag, env, this);
    if (try iterator.next()) |node| {
        return try createNode(env, node);
    } else {
        return try n.getNull(env);
    }
}

// Utilities

fn createNode(env: c.napi_env, node: okra.Node) !c.napi_value {
    const result = try n.createObject(env);

    const level_property = try n.createString(env, "level");
    const level = try n.createUint32(env, node.level);
    try n.setProperty(env, result, level_property, level);

    const key_property = try n.createString(env, "key");
    if (node.key) |key| {
        try n.setProperty(env, result, key_property, try n.createTypedArray(u8, env, key));
    } else {
        try n.setProperty(env, result, key_property, try n.getNull(env));
    }

    const hash_property = try n.createString(env, "hash");
    const hash = try n.createTypedArray(u8, env, node.hash);
    try n.setProperty(env, result, hash_property, hash);

    if (node.value) |value| {
        const value_property = try n.createString(env, "value");
        try n.setProperty(env, result, value_property, try n.createTypedArray(u8, env, value));
    }

    return result;
}

fn parseLevel(env: c.napi_env, levelValue: c.napi_value) !u8 {
    const level = try n.parseUint32(env, levelValue);
    if (level < 0xFF) {
        return @intCast(u8, level);
    } else {
        return n.throwRangeError(env, "level must be less than 255");
    }
}

fn parseKey(env: c.napi_env, key: c.napi_value) !?[]const u8 {
    return switch (try n.typeOf(env, key)) {
        c.napi_null => null,
        else => try n.parseTypedArray(u8, env, key),
    };
}

fn parseBound(env: c.napi_env, bound: c.napi_value) !?okra.Iterator.Bound {
    const dbi_type = try n.typeOf(env, bound);
    if (dbi_type == c.napi_null) {
        return null;
    }

    const key_property = try n.createString(env, "key");
    const key_value = try n.getProperty(env, bound, key_property);

    const inclusive_property = try n.createString(env, "inclusive");
    const inclusive_value = try n.getProperty(env, bound, inclusive_property);

    return okra.Iterator.Bound{
        .key = try parseKey(env, key_value),
        .inclusive = try n.parseBoolean(env, inclusive_value),
    };
}
