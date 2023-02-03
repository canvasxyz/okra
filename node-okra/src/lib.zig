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

const CursorTypeTag = c.napi_type_tag{
    .lower = 0x7311FA8C57A94355,
    .upper = 0x93FEEF1DF0E5C0B4,
};

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.C) c.napi_value {
    const treeMethods = [_]n.Method{
        comptime n.createMethod("close", 0, treeCloseMethod),
    };

    n.defineClass("Tree", 2, createTree, &treeMethods, env, exports) catch return null;

    const transactionMethods = [_]n.Method{
        comptime n.createMethod("abort", 0, transactionAbortMethod),
        comptime n.createMethod("commit", 0, transactionCommitMethod),
        comptime n.createMethod("get", 1, transactionGetMethod),
        comptime n.createMethod("set", 2, transactionSetMethod),
        comptime n.createMethod("delete", 1, transactionDeleteMethod),
        comptime n.createMethod("getNode", 2, transactionGetNodeMethod),
        comptime n.createMethod("getRoot", 0, transactionGetRootMethod),
        comptime n.createMethod("getChildren", 2, transactionGetChildrenMethod),
    };

    n.defineClass("Transaction", 2, createTransaction, &transactionMethods, env, exports) catch return null;

    const cursorMethods = [_]n.Method{
        comptime n.createMethod("close", 0, cursorCloseMethod),
        comptime n.createMethod("goToRoot", 0, cursorGoToRootMethod),
        comptime n.createMethod("goToNode", 2, cursorGoToNodeMethod),
        comptime n.createMethod("goToNext", 0, cursorGoToNextMethod),
        comptime n.createMethod("goToPrevious", 0, cursorGoToPreviousMethod),
        comptime n.createMethod("seek", 2, cursorSeekMethod),
        comptime n.createMethod("getCurrentNode", 0, cursorGetCurrentNodeMethod),
    };

    n.defineClass("Cursor", 1, createCursor, &cursorMethods, env, exports) catch return null;

    return exports;
}

// Tree

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
    try tree.init(allocator, path, .{ .map_size = map_size, .dbs = dbs.items });
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

// Transaction

pub fn createTransaction(env: c.napi_env, this: c.napi_value, args: *const [2]c.napi_value) !c.napi_value {
    const tree = try n.unwrap(okra.Tree, &TreeTypeTag, env, args[0]);

    const read_only_property = try n.createString(env, "readOnly");
    const read_only_value = try n.getProperty(env, args[1], read_only_property);
    const read_only_value_type = try n.typeOf(env, read_only_value);

    var read_only = true;
    if (read_only_value_type != c.napi_undefined) {
        read_only = try n.parseBoolean(env, read_only_value);
    }

    const dbi_property = try n.createString(env, "dbi");
    const dbi_value = try n.getProperty(env, args[1], dbi_property);
    const dbi_value_type = try n.typeOf(env, dbi_value);

    const txn = try allocator.create(okra.Transaction);

    if (dbi_value_type != c.napi_undefined) {
        const dbi = try n.parseStringAlloc(env, dbi_value, allocator);
        defer allocator.free(dbi);
        try txn.init(allocator, tree, .{ .read_only = read_only, .dbi = dbi.ptr });
    } else {
        try txn.init(allocator, tree, .{ .read_only = read_only, .dbi = null });
    }

    try n.wrap(okra.Transaction, env, this, txn, destroyTransaction, &TransactionTypeTag);

    return try n.getUndefined(env);
}

pub fn destroyTransaction(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const txn = @ptrCast(*okra.Transaction, @alignCast(@alignOf(okra.Transaction), ptr));
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

    const key = try n.parseBuffer(env, args[0]);
    const value = try txn.get(key);

    if (value) |bytes| {
        return try n.createBuffer(env, bytes);
    } else {
        return try n.getNull(env);
    }
}

fn transactionSetMethod(env: c.napi_env, this: c.napi_value, args: *const [2]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);

    const key = try n.parseBuffer(env, args[0]);
    const value = try n.parseBuffer(env, args[1]);
    try txn.set(key, value);

    return try n.getUndefined(env);
}

fn transactionDeleteMethod(env: c.napi_env, this: c.napi_value, args: *const [1]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);

    const key = try n.parseBuffer(env, args[0]);
    try txn.delete(key);

    return try n.getUndefined(env);
}

fn transactionGetNodeMethod(env: c.napi_env, this: c.napi_value, args: *const [2]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);

    const level = try parseLevel(env, args[0]);
    const key = try parseKey(env, args[1]);

    if (try txn.getNode(level, key)) |node| {
        return try createNode(env, node);
    } else {
        return error.KeyNotFound;
    }
}

fn transactionGetRootMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, this);

    const root = try txn.getRoot();
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

    var cursor = try okra.Cursor.open(allocator, txn);
    defer cursor.close();

    const first_child = try cursor.goToNode(level - 1, key);
    const first_child_node = try createNode(env, first_child);
    try children.append(first_child_node);

    while (try cursor.goToNext()) |next_child| {
        if (next_child.isSplit()) {
            break;
        } else {
            const next_child_node = try createNode(env, next_child);
            try children.append(next_child_node);
        }
    }

    return try n.wrapArray(env, children.items);
}

// Cursor

pub fn createCursor(env: c.napi_env, this: c.napi_value, args: *const [1]c.napi_value) !c.napi_value {
    const txn = try n.unwrap(okra.Transaction, &TransactionTypeTag, env, args[0]);

    const cursor = try allocator.create(okra.Cursor);

    try cursor.init(allocator, txn);

    try n.wrap(okra.Cursor, env, this, cursor, destroyCursor, &CursorTypeTag);
    return try n.getUndefined(env);
}

pub fn destroyCursor(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const cursor = @ptrCast(*okra.Cursor, @alignCast(@alignOf(okra.Cursor), ptr));
        allocator.destroy(cursor);
    }
}

fn cursorCloseMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const cursor = try n.unwrap(okra.Cursor, &CursorTypeTag, env, this);
    cursor.close();

    return try n.getUndefined(env);
}

fn cursorGoToRootMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const cursor = try n.unwrap(okra.Cursor, &CursorTypeTag, env, this);

    const root = try cursor.goToRoot();

    return try createNode(env, root);
}

fn cursorGoToNodeMethod(env: c.napi_env, this: c.napi_value, args: *const [2]c.napi_value) !c.napi_value {
    const cursor = try n.unwrap(okra.Cursor, &CursorTypeTag, env, this);

    const level = try parseLevel(env, args[0]);
    const key = try parseKey(env, args[1]);

    const node = try cursor.goToNode(level, key);

    return try createNode(env, node);
}

fn cursorGoToNextMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const cursor = try n.unwrap(okra.Cursor, &CursorTypeTag, env, this);
    if (try cursor.goToNext()) |node| {
        return try createNode(env, node);
    } else {
        return try n.getNull(env);
    }
}

fn cursorGoToPreviousMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const cursor = try n.unwrap(okra.Cursor, &CursorTypeTag, env, this);
    if (try cursor.goToPrevious()) |node| {
        return try createNode(env, node);
    } else {
        return try n.getNull(env);
    }
}

fn cursorSeekMethod(env: c.napi_env, this: c.napi_value, args: *const [2]c.napi_value) !c.napi_value {
    const cursor = try n.unwrap(okra.Cursor, &CursorTypeTag, env, this);

    const level = try parseLevel(env, args[0]);
    const key = try parseKey(env, args[1]);

    if (try cursor.seek(level, key)) |node| {
        return try createNode(env, node);
    } else {
        return try n.getNull(env);
    }
}

fn cursorGetCurrentNodeMethod(env: c.napi_env, this: c.napi_value, _: *const [0]c.napi_value) !c.napi_value {
    const cursor = try n.unwrap(okra.Cursor, &CursorTypeTag, env, this);
    const node = try cursor.getCurrentNode();
    return try createNode(env, node);
}

fn createNode(env: c.napi_env, node: okra.Node) !c.napi_value {
    const result = try n.createObject(env);

    const level_property = try n.createString(env, "level");
    const level = try n.createUint32(env, node.level);
    try n.setProperty(env, result, level_property, level);

    const key_property = try n.createString(env, "key");
    if (node.key) |key| {
        try n.setProperty(env, result, key_property, try n.createBuffer(env, key));
    } else {
        try n.setProperty(env, result, key_property, try n.getNull(env));
    }

    const hash_property = try n.createString(env, "hash");
    const hash = try n.createBuffer(env, node.hash);
    try n.setProperty(env, result, hash_property, hash);

    if (node.value) |value| {
        const value_property = try n.createString(env, "value");
        try n.setProperty(env, result, value_property, try n.createBuffer(env, value));
    }

    return result;
}

fn parseLevel(env: c.napi_env, levelValue: c.napi_value) !u8 {
    const level = try n.parseUint32(env, levelValue);
    if (level > 0xFF) {
        return n.throwRangeError(env, "level must be less than 256");
    } else {
        return @intCast(u8, level);
    }
}

fn parseKey(env: c.napi_env, keyValue: c.napi_value) !?[]const u8 {
    const keyType = try n.typeOf(env, keyValue);
    switch (keyType) {
        c.napi_null => {
            return null;
        },
        c.napi_object => {
            return try n.parseBuffer(env, keyValue);
        },
        else => {
            return n.throwTypeError(env, "expected Buffer or null");
        },
    }
}
