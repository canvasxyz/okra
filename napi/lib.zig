const std = @import("std");
const assert = std.debug.assert;
const hex = std.fmt.fmtSliceHexLower;
const allocator = std.heap.c_allocator;

const okra = @import("okra");
const c = @import("./c.zig");
const n = @import("./n.zig");

const X: comptime_int = 14;
const V: comptime_int = 32;
const Q: comptime_int = 0x42;
const Node = okra.Node(X);
const Tree = okra.Tree(X, Q);
const Source = okra.Source(X, Q);
const Target = okra.Target(X, Q);

const TreeTypeTag: c.napi_type_tag = .{ .lower = 0x1B67FCDD82CD4514, .upper = 0xB2B9016A53BAF0F9 };

const SourceTypeTag: c.napi_type_tag = .{
    .lower = 0xF727CF6D5C254E54,
    .upper = 0xB5EDCA98B9F7AA6F,
};

const TargetTypeTag: c.napi_type_tag = .{
    .lower = 0x7311FA8C57A94355,
    .upper = 0x93FEEF1DF0E5C0B4,
};

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.C) c.napi_value {
    const treeMethods = [_]n.Method{
        .{ .name = "close", .callback = treeCloseMethod },
        .{ .name = "insert", .callback = treeInsertMethod },
    };

    n.defineClass("Tree", createTree, treeMethods.len, &treeMethods, env, exports) catch return null;

    const sourceMethods = [_]n.Method{
        .{ .name = "close", .callback = sourceCloseMethod },
        .{ .name = "getRootLevel", .callback = sourceGetRootLevelMethod },
        .{ .name = "getRootHash", .callback = sourceGetRootHashMethod },
        .{ .name = "getChildren", .callback = sourceGetChildrenMethod },
    };

    n.defineClass("Source", createSource, sourceMethods.len, &sourceMethods, env, exports) catch return null;

    const targetMethods = [_]n.Method{
        .{ .name = "close", .callback = targetCloseMethod },
        .{ .name = "getRootLevel", .callback = targetGetRootLevelMethod },
        .{ .name = "getRootHash", .callback = targetGetRootHashMethod },
        .{ .name = "seek", .callback = targetSeekMethod },
        .{ .name = "filter", .callback = targetFilterMethod },
        // .{ .name = "insert", .callback = targetInsertMethod },
    };

    n.defineClass("Target", createTarget, targetMethods.len, &targetMethods, env, exports) catch return null;

    return exports;
}

pub fn createTree(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(1, env, info) catch return null;
    const pathArg = stat.argv[0];

    const path = n.parseStringAlloc(env, pathArg, allocator) catch return null;
    defer allocator.free(path);

    const tree = allocator.create(Tree) catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    };

    tree.init(allocator, path, .{}) catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    };

    n.wrap(Tree, env, stat.thisArg, tree, destroyTree, &TreeTypeTag) catch return null;

    return n.getUndefined(env) catch return null;
}

pub fn destroyTree(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const tree = @ptrCast(*Tree, @alignCast(@alignOf(Tree), ptr));
        tree.close();
        allocator.destroy(tree);
    }
}

fn treeCloseMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const tree = n.unwrap(Tree, &TreeTypeTag, env, stat.thisArg, true) catch return null;
    tree.close();

    return n.getUndefined(env) catch return null;
}

fn treeInsertMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(2, env, info) catch return null;
    const leaf = n.parseBuffer(env, X, stat.argv[0]) catch return null;
    const hash = n.parseBuffer(env, V, stat.argv[1]) catch return null;
    const tree = n.unwrap(Tree, &TreeTypeTag, env, stat.thisArg, false) catch return null;

    if (tree.insert(leaf, hash)) |_| {
        return n.getUndefined(env) catch return null;
    } else |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    }
}

// Source

pub fn createSource(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(1, env, info) catch return null;
    const tree = n.unwrap(Tree, &TreeTypeTag, env, stat.argv[0], false) catch return null;

    const source = allocator.create(Source) catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    };

    source.init(allocator, tree) catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    };

    n.wrap(Source, env, stat.thisArg, source, destroySource, &SourceTypeTag) catch return null;
    return n.getUndefined(env) catch return null;
}

pub fn destroySource(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const source = @ptrCast(*Source, @alignCast(@alignOf(Source), ptr));
        source.close();
        allocator.destroy(source);
    }
}

fn sourceCloseMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const source = n.unwrap(Source, &SourceTypeTag, env, stat.thisArg, true) catch return null;
    source.close();

    return n.getUndefined(env) catch return null;
}

fn sourceGetRootLevelMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const source = n.unwrap(Source, &SourceTypeTag, env, stat.thisArg, false) catch return null;

    var result: c.napi_value = undefined;
    if (c.napi_create_uint32(env, source.rootLevel, &result) != c.napi_ok) {
        _ = c.napi_throw_error(env, null, "failed to create unsigned integer");
        return null;
    }

    return result;
}

fn sourceGetRootHashMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const source = n.unwrap(Source, &SourceTypeTag, env, stat.thisArg, false) catch return null;

    return n.createBuffer(env, &source.rootValue) catch return null;
}

fn sourceGetChildrenMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(2, env, info) catch return null;

    const level = n.parseUint32(env, stat.argv[0]) catch return null;

    const leafValueType = n.typeOf(env, stat.argv[1]) catch return null;
    const leaf = switch (leafValueType) {
        c.napi_null => &[_]u8{0} ** X,
        c.napi_object => n.parseBuffer(env, X, stat.argv[1]) catch return null,
        else => {
            _ = c.napi_throw_type_error(env, null, "expected Buffer or null");
            return null;
        },
    };

    const source = n.unwrap(Source, &SourceTypeTag, env, stat.thisArg, false) catch return null;

    if (level > 0xFFFF) {
        _ = c.napi_throw_range_error(env, null, "level out of range");
        return null;
    }

    var nodes = std.ArrayList(Node).init(allocator);
    defer nodes.deinit();
    source.getChildren(@intCast(u16, level), leaf, &nodes) catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    };

    const leafProperty = n.createString(env, "leaf") catch return null;
    const hashProperty = n.createString(env, "hash") catch return null;
    const resultArray = n.createArrayWithLength(env, nodes.items.len) catch return null;
    for (nodes.items) |node, i| {
        const leafBuffer = n.createBuffer(env, &node.leaf) catch return null;
        const hashBuffer = n.createBuffer(env, &node.hash) catch return null;
        const object = n.createObject(env) catch return null;
        n.setProperty(env, object, leafProperty, leafBuffer) catch return null;
        n.setProperty(env, object, hashProperty, hashBuffer) catch return null;
        n.setElement(env, resultArray, @intCast(u32, i), object) catch return null;
    }

    return resultArray;
}

// Target

pub fn createTarget(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(1, env, info) catch return null;
    const tree = n.unwrap(Tree, &TreeTypeTag, env, stat.argv[0], false) catch return null;

    const target = allocator.create(Target) catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    };

    target.init(allocator, tree) catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_error(env, null, name.ptr);
        return null;
    };

    n.wrap(Target, env, stat.thisArg, target, destroyTarget, &TargetTypeTag) catch return null;
    return n.getUndefined(env) catch return null;
}

pub fn destroyTarget(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    if (finalize_data) |ptr| {
        const target = @ptrCast(*Target, @alignCast(@alignOf(Target), ptr));
        target.close();
        allocator.destroy(target);
    }
}

fn targetCloseMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const target = n.unwrap(Target, &TargetTypeTag, env, stat.thisArg, true) catch return null;
    target.close();

    return n.getUndefined(env) catch return null;
}

fn targetGetRootLevelMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const target = n.unwrap(Target, &TargetTypeTag, env, stat.thisArg, false) catch return null;

    var result: c.napi_value = undefined;
    if (c.napi_create_uint32(env, target.rootLevel, &result) != c.napi_ok) {
        _ = c.napi_throw_error(env, null, "failed to create unsigned integer");
        return null;
    }

    return result;
}

fn targetGetRootHashMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(0, env, info) catch return null;
    const target = n.unwrap(Target, &TargetTypeTag, env, stat.thisArg, false) catch return null;

    return n.createBuffer(env, &target.rootValue) catch return null;
}

fn targetFilterMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(1, env, info) catch return null;
    const target = n.unwrap(Target, &TargetTypeTag, env, stat.thisArg, false) catch return null;

    var arrayValue = stat.argv[0];
    var isArray: bool = false;
    if (c.napi_is_array(env, arrayValue, &isArray) != c.napi_ok) {
        _ = c.napi_throw_error(env, null, "failed to validate array");
        return null;
    } else if (!isArray) {
        _ = c.napi_throw_error(env, null, "expected Array");
        return null;
    }

    var nodes = std.ArrayList(c.napi_value).init(allocator);
    defer nodes.deinit();

    const leafProperty = n.createString(env, "leaf") catch return null;
    const hashProperty = n.createString(env, "hash") catch return null;

    var length: u32 = 0;
    if (c.napi_get_array_length(env, arrayValue, &length) != c.napi_ok) {
        _ = c.napi_throw_error(env, null, "failed to get array length");
        return null;
    }

    var key = Tree.createKey(0, null);

    var index: u32 = 0;
    while (index < length) : (index += 1) {
        var element = n.getElement(env, arrayValue, index) catch return null;

        const leaf = n.getProperty(env, element, leafProperty) catch return null;
        const leafBytes = n.parseBuffer(env, X, leaf) catch return null;
        const hash = n.getProperty(env, element, hashProperty) catch return null;
        const valueBytes = n.parseBuffer(env, V, hash) catch return null;

        Tree.setLeaf(&key, leafBytes);
        if (target.txn.get(target.tree.dbi, &key)) |value| {
            if (value) |bytes| {
                if (!std.mem.eql(u8, bytes, valueBytes)) {
                    _ = c.napi_throw_error(env, null, "Conflict");
                    return null;
                }
            } else {
                nodes.append(element) catch |err| {
                    const name = @errorName(err);
                    _ = c.napi_throw_error(env, null, name.ptr);
                    return null;
                };
            }
        } else |err| {
            const name = @errorName(err);
            _ = c.napi_throw_error(env, null, name.ptr);
            return null;
        }
    }

    return n.wrapArray(env, nodes.items) catch return null;
}

fn targetSeekMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    const stat = n.parseCallbackInfo(2, env, info) catch return null;
    const target = n.unwrap(Target, &TargetTypeTag, env, stat.thisArg, false) catch return null;

    const level = n.parseUint32(env, stat.argv[0]) catch return null;
    const sourceRoot = n.parseBuffer(env, X, stat.argv[1]) catch return null;

    if (level == 0 or level > target.rootLevel) {
        _ = c.napi_throw_range_error(env, null, "out of range");
        return null;
    }

    const pointer = target.seek(@intCast(u16, level), sourceRoot) catch |err| {
        const name = @errorName(err);
        _ = c.napi_throw_range_error(env, null, name.ptr);
        return null;
    };

    const leaf = n.createBuffer(env, Tree.getLeaf(pointer.key)) catch return null;
    const hash = n.createBuffer(env, pointer.value) catch return null;

    const object = n.createObject(env) catch return null;
    const leafProperty = n.createString(env, "leaf") catch return null;
    const hashProperty = n.createString(env, "hash") catch return null;
    n.setProperty(env, object, leafProperty, leaf) catch return null;
    n.setProperty(env, object, hashProperty, hash) catch return null;

    return object;
}

// fn targetInsertMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
//   const stat = n.parseCallbackInfo(2, env, info) catch return null;
//   const leaf = n.parseBuffer(env, X, stat.argv[0]) catch return null;
//   const hash = n.parseBuffer(env, V, stat.argv[1]) catch return null;
//   const target = n.unwrap(Target, &TargetTypeTag, env, stat.thisArg, false) catch return null;

//   if (target.insert(leaf, hash)) |_| {
//     return n.getUndefined(env) catch return null;
//   } else |err| {
//     _ = c.napi_throw_error(env, null, @errorName(err));
//     return null;
//   }
// }
