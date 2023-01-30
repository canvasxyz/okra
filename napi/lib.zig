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
        .{ .name = "close", .callback = treeCloseMethod },
    };

    n.defineClass("Tree", createTree, &treeMethods, env, exports) catch return null;

    const transactionMethods = [_]n.Method{
        .{ .name = "abort", .callback = transactionAbortMethod },
        .{ .name = "commit", .callback = transactionCommitMethod },
        .{ .name = "get", .callback = transactionGetMethod },
        .{ .name = "set", .callback = transactionSetMethod },
        .{ .name = "delete", .callback = transactionDeleteMethod },
        .{ .name = "getNode", .callback = transactionGetNodeMethod },
        .{ .name = "getChildren", .callback = transactionGetChildrenMethod },
    };

    n.defineClass("Transaction", createTransaction, &transactionMethods, env, exports) catch return null;

    const cursorMethods = [_]n.Method{
        .{ .name = "close", .callback = cursorCloseMethod },
        .{ .name = "goToRoot", .callback = cursorGoToRootMethod },
        .{ .name = "goToNode", .callback = cursorGoToNodeMethod },
        .{ .name = "goToNext", .callback = cursorGoToNextMethod },
        .{ .name = "goToPrevious", .callback = cursorGoToPreviousMethod },
        .{ .name = "seek", .callback = cursorSeekMethod },
        .{ .name = "getCurrentNode", .callback = cursorGetCurrentNodeMethod },
    };

    n.defineClass("Cursor", createCursor, &cursorMethods, env, exports) catch return null;

    return exports;
}

// Tree

pub fn createTree(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(1, env, info) catch return null;
    const pathArg = stat.args[0];

    const path = n.parseStringAlloc(env, pathArg, allocator) catch return null;
    defer allocator.free(path);

    const tree = allocator.create(okra.Tree) catch |err| return n.throw(env, err);

    tree.init(allocator, path, .{}) catch |err| return n.throw(env, err);

    n.wrap(okra.Tree, env, stat.this, tree, destroyTree, &TreeTypeTag) catch return null;

    return n.getUndefined(env) catch return null;
}

pub fn destroyTree(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const tree = @ptrCast(*okra.Tree, @alignCast(@alignOf(okra.Tree), ptr));

        tree.close();
        allocator.destroy(tree);
    }
}

fn treeCloseMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const tree = n.unwrap(okra.Tree, &TreeTypeTag, env, stat.this, true) catch return null;
    defer allocator.destroy(tree);

    tree.close();

    return n.getUndefined(env) catch return null;
}

// Transaction

pub fn createTransaction(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(2, env, info) catch return null;
    const tree = n.unwrap(okra.Tree, &TreeTypeTag, env, stat.args[0], false) catch return null;

    const read_only_property = n.createString(env, "readOnly") catch return null;
    const read_only_value = n.getProperty(env, stat.args[1], read_only_property) catch return null;
    const read_only = n.parseBoolean(env, read_only_value) catch return null;

    const txn = allocator.create(okra.Transaction) catch |err| return n.throw(env, err);

    txn.init(allocator, tree, .{ .read_only = read_only }) catch |err| return n.throw(env, err);

    n.wrap(okra.Transaction, env, stat.this, txn, destroyTransaction, &TransactionTypeTag) catch return null;
    return n.getUndefined(env) catch return null;
}

pub fn destroyTransaction(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const txn = @ptrCast(*okra.Transaction, @alignCast(@alignOf(okra.Transaction), ptr));
        txn.abort();
        allocator.destroy(txn);
    }
}

fn transactionAbortMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const txn = n.unwrap(okra.Transaction, &TransactionTypeTag, env, stat.this, true) catch return null;
    defer allocator.destroy(txn);

    txn.abort();
    return n.getUndefined(env) catch return null;
}

fn transactionCommitMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const txn = n.unwrap(okra.Transaction, &TransactionTypeTag, env, stat.this, true) catch return null;
    defer allocator.destroy(txn);

    txn.commit() catch |err| return n.throw(env, err);

    return n.getUndefined(env) catch return null;
}

fn transactionGetMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(1, env, info) catch return null;
    const txn = n.unwrap(okra.Transaction, &TransactionTypeTag, env, stat.this, false) catch return null;

    const key = n.parseBuffer(env, stat.args[0]) catch return null;
    const value = txn.get(key) catch |err| return n.throw(env, err);

    if (value) |bytes| {
        return n.createBuffer(env, bytes) catch return null;
    } else {
        return n.getNull(env) catch return null;
    }
}

fn transactionSetMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(2, env, info) catch return null;
    const txn = n.unwrap(okra.Transaction, &TransactionTypeTag, env, stat.this, false) catch return null;

    const key = n.parseBuffer(env, stat.args[0]) catch return null;
    const value = n.parseBuffer(env, stat.args[1]) catch return null;
    txn.set(key, value) catch |err| return n.throw(env, err);

    return n.getUndefined(env) catch return null;
}

fn transactionDeleteMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(1, env, info) catch return null;
    const txn = n.unwrap(okra.Transaction, &TransactionTypeTag, env, stat.this, false) catch return null;

    const key = n.parseBuffer(env, stat.args[0]) catch return null;
    txn.delete(key) catch |err| return n.throw(env, err);

    return n.getUndefined(env) catch return null;
}

fn transactionGetNodeMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(2, env, info) catch return null;
    const txn = n.unwrap(okra.Transaction, &TransactionTypeTag, env, stat.this, false) catch return null;

    const level = parseLevel(env, stat.args[0]) catch return null;
    const key = parseKey(env, stat.args[1]) catch return null;

    if (txn.getNode(level, key) catch |err| return n.throw(env, err)) |node| {
        return createNode(env, node) catch return null;
    } else {
        return n.throw(env, error.KeyNotFound);
    }
}

fn transactionGetChildrenMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(2, env, info) catch return null;
    const txn = n.unwrap(okra.Transaction, &TransactionTypeTag, env, stat.this, false) catch return null;

    const level = parseLevel(env, stat.args[0]) catch return null;
    const key = parseKey(env, stat.args[1]) catch return null;

    if (level == 0) {
        _ = c.napi_throw_range_error(env, null, "cannot get children of a leaf node");
        return null;
    }

    var children = std.ArrayList(c.napi_value).init(allocator);
    defer children.deinit();

    var cursor = okra.Cursor.open(allocator, txn) catch |err| return n.throw(env, err);
    defer cursor.close();

    const first_child = cursor.goToNode(level - 1, key) catch |err| return n.throw(env, err);
    const first_child_node = createNode(env, first_child) catch return null;
    children.append(first_child_node) catch |err| return n.throw(env, err);

    while (cursor.goToNext() catch |err| return n.throw(env, err)) |next_child| {
        if (next_child.isSplit()) {
            break;
        } else {
            const next_child_node = createNode(env, next_child) catch return null;
            children.append(next_child_node) catch |err| return n.throw(env, err);
        }
    }

    return n.wrapArray(env, children.items) catch return null;
}

// Cursor

pub fn createCursor(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(1, env, info) catch return null;
    const txn = n.unwrap(okra.Transaction, &TransactionTypeTag, env, stat.args[0], false) catch return null;

    const cursor = allocator.create(okra.Cursor) catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    };

    cursor.init(allocator, txn) catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    };

    n.wrap(okra.Cursor, env, stat.this, cursor, destroyCursor, &CursorTypeTag) catch return null;
    return n.getUndefined(env) catch return null;
}

pub fn destroyCursor(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const cursor = @ptrCast(*okra.Cursor, @alignCast(@alignOf(okra.Cursor), ptr));
        cursor.close();
        allocator.destroy(cursor);
    }
}

fn cursorCloseMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const cursor = n.unwrap(okra.Cursor, &CursorTypeTag, env, stat.this, true) catch return null;
    defer allocator.destroy(cursor);
    cursor.close();

    return n.getUndefined(env) catch return null;
}

fn cursorGoToRootMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const cursor = n.unwrap(okra.Cursor, &CursorTypeTag, env, stat.this, false) catch return null;

    const root = cursor.goToRoot() catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    };

    return createNode(env, root) catch return null;
}

fn cursorGoToNodeMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(2, env, info) catch return null;
    const cursor = n.unwrap(okra.Cursor, &CursorTypeTag, env, stat.this, false) catch return null;

    const level = parseLevel(env, stat.args[0]) catch return null;
    const key = parseKey(env, stat.args[1]) catch return null;

    const node = cursor.goToNode(level, key) catch |err| return n.throw(env, err);

    return createNode(env, node) catch return null;
}

fn cursorGoToNextMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const cursor = n.unwrap(okra.Cursor, &CursorTypeTag, env, stat.this, false) catch return null;

    const next = cursor.goToNext() catch |err| return n.throw(env, err);

    if (next) |node| {
        return createNode(env, node) catch return null;
    } else {
        return n.getNull(env) catch return null;
    }
}

fn cursorGoToPreviousMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const cursor = n.unwrap(okra.Cursor, &CursorTypeTag, env, stat.this, false) catch return null;

    const previous = cursor.goToPrevious() catch |err| return n.throw(env, err);

    if (previous) |node| {
        return createNode(env, node) catch return null;
    } else {
        return n.getNull(env) catch return null;
    }
}

fn cursorSeekMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(2, env, info) catch return null;
    const cursor = n.unwrap(okra.Cursor, &CursorTypeTag, env, stat.this, false) catch return null;

    const level = parseLevel(env, stat.args[0]) catch return null;
    const key = parseKey(env, stat.args[1]) catch return null;

    const seek = cursor.seek(level, key) catch |err| return n.throw(env, err);

    if (seek) |node| {
        return createNode(env, node) catch return null;
    } else {
        return n.getNull(env) catch return null;
    }
}

fn cursorGetCurrentNodeMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const cursor = n.unwrap(okra.Cursor, &CursorTypeTag, env, stat.this, false) catch return null;
    const node = cursor.getCurrentNode() catch |err| return n.throw(env, err);

    return createNode(env, node) catch return null;
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
        _ = c.napi_throw_range_error(env, null, "level must be less than 256");
        return n.Error.Exception;
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
            _ = c.napi_throw_type_error(env, null, "expected Buffer or null");
            return n.Error.Exception;
        },
    }
}
