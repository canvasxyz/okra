const std = @import("std");
const assert = std.debug.assert;
const hex = std.fmt.fmtSliceHexLower;
const allocator = std.heap.c_allocator;

const okra = @import("okra");
const c = @import("./c.zig");
const n = @import("./n.zig");

const X: comptime_int = 6;
const V: comptime_int = 32;
const Q: comptime_int = 0x42;

const TreeTypeTag: c.napi_type_tag = .{
  .lower = 0x1B67FCDD82CD4514,
  .upper = 0xB2B9016A53BAF0F9
};

const ScannerTypeTag: c.napi_type_tag = .{
  .lower = 0xF727CF6D5C254E54,
  .upper = 0xB5EDCA98B9F7AA6F,
};

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.C) c.napi_value {
  const treeMethods = [_]n.Method{
    .{ .name = "close", .callback = treeCloseMethod },
    .{ .name = "insert", .callback = treeInsertMethod },
  };

  n.defineClass("Tree", createTree, treeMethods.len, &treeMethods, env, exports) catch return null;
  
  const scannerMethods = [_]n.Method{
    .{ .name = "close", .callback = scannerCloseMethod },
    .{ .name = "getRootLevel", .callback = scannerGetRootLevelMethod },
    .{ .name = "seek", .callback = scannerSeekMethod },
  };

  n.defineClass("Scanner", createScanner, scannerMethods.len, &scannerMethods, env, exports) catch return null;

  return exports;
}

pub fn createTree(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = n.parseCallbackInfo(1, env, info) catch return null;
  const pathArg = stat.argv[0];

  const path = n.parseStringAlloc(env, pathArg, allocator) catch return null;
  defer allocator.free(path);

  const tree = allocator.create(okra.Tree(X, Q)) catch |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  };

  tree.init(allocator, path, .{}) catch |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  };

  n.wrap(okra.Tree(X, Q), env, stat.thisArg, tree, destroyTree, &TreeTypeTag) catch return null;

  return n.getUndefined(env) catch return null;
}

pub fn destroyTree(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
  if (finalize_data) |ptr| {
    const tree = @ptrCast(*okra.Tree(X, Q), @alignCast(@alignOf(okra.Tree(X, Q)), ptr));
    tree.close();
    allocator.destroy(tree);
  }
}

fn treeCloseMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = n.parseCallbackInfo(0, env, info) catch return null;
  const tree = n.unwrap(okra.Tree(X, Q), &TreeTypeTag, env, stat.thisArg, true) catch return null;
  tree.close();

  return n.getUndefined(env) catch return null;
}

fn treeInsertMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = n.parseCallbackInfo(2, env, info) catch return null;
  const leaf = n.parseBuffer(env, X, stat.argv[0]) catch return null;
  const hash = n.parseBuffer(env, V, stat.argv[1]) catch return null;
  const tree = n.unwrap(okra.Tree(X, Q), &TreeTypeTag, env, stat.thisArg, false) catch return null;

  if (tree.insert(leaf, hash)) |_| {
    return n.getUndefined(env) catch return null;
  } else |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  }
}

// Scanner 
pub fn createScanner(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = n.parseCallbackInfo(1, env, info) catch return null;
  const tree = n.unwrap(okra.Tree(X, Q), &TreeTypeTag, env, stat.argv[0], false) catch return null;

  const scanner = allocator.create(okra.Scanner(X, Q)) catch |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  };

  scanner.init(allocator, tree) catch |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  };

  n.wrap(okra.Scanner(X, Q), env, stat.thisArg, scanner, destroyScanner, &ScannerTypeTag) catch return null;
  return n.getUndefined(env) catch return null;
}

pub fn destroyScanner(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
  if (finalize_data) |ptr| {
    const scanner = @ptrCast(*okra.Scanner(X, Q), @alignCast(@alignOf(okra.Scanner(X, Q)), ptr));
    scanner.close();
    allocator.destroy(scanner);
  }
}

fn scannerCloseMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = n.parseCallbackInfo(0, env, info) catch return null;
  const scanner = n.unwrap(okra.Scanner(X, Q), &ScannerTypeTag, env, stat.thisArg, true) catch return null;
  scanner.close();

  return n.getUndefined(env) catch return null;
}

fn scannerGetRootLevelMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = n.parseCallbackInfo(0, env, info) catch return null;
  const scanner = n.unwrap(okra.Scanner(X, Q), &ScannerTypeTag, env, stat.thisArg, false) catch return null;

  var result: c.napi_value = undefined;
  if (c.napi_create_uint32(env, scanner.rootLevel, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create unsigned integer");
    return null;
  }

  return result;
}

fn scannerSeekMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = n.parseCallbackInfo(2, env, info) catch return null;

  const level = n.parseUint32(env, stat.argv[0]) catch return null;

  const leafValueType = n.typeOf(env, stat.argv[1]) catch return null;
  const leaf = switch (leafValueType) {
    c.napi_null => &[_]u8 { 0 } ** X,
    c.napi_object => n.parseBuffer(env, X, stat.argv[1]) catch return null,
    else => {
        _ = c.napi_throw_type_error(env, null, "expected Buffer or null");
      return null;
    },
  };

  const scanner = n.unwrap(okra.Scanner(X, Q), &ScannerTypeTag, env, stat.thisArg, false) catch return null;

  if (level > 0xFFFF) {
    _ = c.napi_throw_range_error(env, null, "level out of range");
    return null;
  }

  scanner.seek(@intCast(u16, level), leaf) catch |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  };

  var resultArray: c.napi_value = undefined;
  if (c.napi_create_array_with_length(env, scanner.nodes.items.len, &resultArray) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create array");
    return null;
  }

  for (scanner.nodes.items) |node, i| {
    const leafBuffer = n.createBuffer(env, node.key[2..]) catch return null;
    const hashBuffer = n.createBuffer(env, &node.value) catch return null;
    const object = n.createObject(env) catch return null;
    n.setProperty(env, object, "leaf", leafBuffer) catch return null;
    n.setProperty(env, object, "hash", hashBuffer) catch return null;
    n.setElement(env, resultArray, @intCast(u32, i), object) catch return null;
  }

  return resultArray;
}
