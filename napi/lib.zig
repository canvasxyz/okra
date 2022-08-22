const std = @import("std");
const assert = std.debug.assert;
const hex = std.fmt.fmtSliceHexLower;
const allocator = std.heap.c_allocator;

const okra = @import("okra");
const c = @import("./c.zig");

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

const Callback = fn(c.napi_env, c.napi_callback_info) callconv(.C) c.napi_value;
const Method = struct {
  name: [*:0]const u8,
  callback: Callback,
}; 

const Error = error { Exception };

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.C) c.napi_value {
  const treeMethods = [_]Method{
    .{ .name = "close", .callback = treeCloseMethod },
    .{ .name = "insert", .callback = treeInsertMethod },
  };

  defineClass("Tree", createTree, treeMethods.len, &treeMethods, env, exports) catch return null;
  
  const scannerMethods = [_]Method{
    .{ .name = "close", .callback = scannerCloseMethod },
    .{ .name = "getRootLevel", .callback = scannerGetRootLevelMethod },
    .{ .name = "seek", .callback = scannerSeekMethod },
  };

  defineClass("Scanner", createScanner, scannerMethods.len, &scannerMethods, env, exports) catch return null;

  return exports;
}

pub fn createTree(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = parseCallbackInfo(1, env, info) catch return null;
  const pathArg = stat.argv[0];

  const path = parseStringAlloc(env, pathArg) catch return null;
  defer allocator.free(path);

  const tree = allocator.create(okra.Tree(X, Q)) catch |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  };

  tree.init(allocator, path, .{}) catch |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  };

  wrap(okra.Tree(X, Q), env, stat.thisArg, tree, destroyTree, &TreeTypeTag) catch return null;

  return getUndefined(env) catch return null;
}

pub fn destroyTree(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
  if (finalize_data) |ptr| {
    const tree = @ptrCast(*okra.Tree(X, Q), @alignCast(@alignOf(okra.Tree(X, Q)), ptr));
    tree.close();
    allocator.destroy(tree);
  }
}

fn treeCloseMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = parseCallbackInfo(0, env, info) catch return null;
  const tree = unwrap(okra.Tree(X, Q), &TreeTypeTag, env, stat.thisArg, true) catch return null;
  tree.close();

  return getUndefined(env) catch return null;
}

fn treeInsertMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = parseCallbackInfo(2, env, info) catch return null;
  const leaf = parseBuffer(env, X, stat.argv[0]) catch return null;
  const hash = parseBuffer(env, V, stat.argv[1]) catch return null;
  const tree = unwrap(okra.Tree(X, Q), &TreeTypeTag, env, stat.thisArg, false) catch return null;

  if (tree.insert(leaf, hash)) |_| {
    return getUndefined(env) catch return null;
  } else |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  }
}

// Scanner 
pub fn createScanner(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = parseCallbackInfo(1, env, info) catch return null;
  const tree = unwrap(okra.Tree(X, Q), &TreeTypeTag, env, stat.argv[0], false) catch return null;

  const scanner = allocator.create(okra.Scanner(X, Q)) catch |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  };

  scanner.init(allocator, tree) catch |err| {
    _ = c.napi_throw_error(env, null, @errorName(err));
    return null;
  };

  wrap(okra.Scanner(X, Q), env, stat.thisArg, scanner, destroyScanner, &ScannerTypeTag) catch return null;
  return getUndefined(env) catch return null;
}

pub fn destroyScanner(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
  if (finalize_data) |ptr| {
    const scanner = @ptrCast(*okra.Scanner(X, Q), @alignCast(@alignOf(okra.Scanner(X, Q)), ptr));
    scanner.close();
    allocator.destroy(scanner);
  }
}

fn scannerCloseMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = parseCallbackInfo(0, env, info) catch return null;
  const scanner = unwrap(okra.Scanner(X, Q), &ScannerTypeTag, env, stat.thisArg, true) catch return null;
  scanner.close();

  return getUndefined(env) catch return null;
}

fn scannerGetRootLevelMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = parseCallbackInfo(0, env, info) catch return null;
  const scanner = unwrap(okra.Scanner(X, Q), &ScannerTypeTag, env, stat.thisArg, false) catch return null;

  var result: c.napi_value = undefined;
  if (c.napi_create_uint32(env, scanner.rootLevel, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create unsigned integer");
    return null;
  }

  return result;
}

fn scannerSeekMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
  const stat = parseCallbackInfo(2, env, info) catch return null;

  const level = parseUint32(env, stat.argv[0]) catch return null;

  const leafValueType = typeOf(env, stat.argv[1]) catch return null;
  const leaf = switch (leafValueType) {
    c.napi_null => &[_]u8 { 0 } ** X,
    c.napi_object => parseBuffer(env, X, stat.argv[1]) catch return null,
    else => {
        _ = c.napi_throw_type_error(env, null, "expected Buffer or null");
      return null;
    },
  };

  const scanner = unwrap(okra.Scanner(X, Q), &ScannerTypeTag, env, stat.thisArg, false) catch return null;

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
    const leafBuffer = createBuffer(env, node.key[2..]) catch return null;
    const hashBuffer = createBuffer(env, &node.value) catch return null;
    const object = createObject(env) catch return null;
    setProperty(env, object, "leaf", leafBuffer) catch return null;
    setProperty(env, object, "hash", hashBuffer) catch return null;
    setElement(env, resultArray, @intCast(u32, i), object) catch return null;
  }

  return resultArray;
}

fn getUndefined(env: c.napi_env) Error!c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_get_undefined(env, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to get undefined");
    return Error.Exception;
  }

  return result;
}

fn defineClass(
  comptime name: [*:0]const u8,
  comptime constructor: Callback,
  comptime methodCount: usize,
  comptime methods: *const [methodCount]Method,
  env: c.napi_env,
  exports: c.napi_value,
) Error!void {
  var properties: [methodCount]c.napi_property_descriptor = undefined;
  for (methods) |method, i| {
    properties[i] = .{
      .utf8name = method.name,
      .name = null,
      .method = method.callback,
      .getter = null,
      .setter = null,
      .value = null,
      .attributes = c.napi_default_method,
      .data = null,
    };
  }
  
  var classValue: c.napi_value = undefined;
  if (c.napi_define_class(env, name, c.NAPI_AUTO_LENGTH, constructor, null, properties.len, &properties, &classValue) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to define class");
    return Error.Exception;
  }

  if (c.napi_set_named_property(env, exports, name, classValue) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to add class constructor to exports");
    return Error.Exception;
  }
}

fn wrap(
  comptime T: type,
  env: c.napi_env,
  value: c.napi_value,
  ptr: *T,
  comptime destructor: fn(c.napi_env, ?*anyopaque, ?*anyopaque) callconv(.C) void,
  tag: *const c.napi_type_tag,
) Error!void {
  if (c.napi_wrap(env, value, ptr, destructor, null, null) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to wrap object");
    return Error.Exception;
  } else if (c.napi_type_tag_object(env, value, tag) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to tag object type");
    return Error.Exception;
  }
}

fn unwrap(comptime T: type, tag: *const c.napi_type_tag, env: c.napi_env, value: c.napi_value, remove: bool) Error!*T {
  var isTag = false;
  if (c.napi_check_object_type_tag(env, value, tag, &isTag) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to check object type tag");
    return Error.Exception;
  } else if (!isTag) {
    _ = c.napi_throw_type_error(env, null, "invalid object type tag");
    return Error.Exception;
  }

  var ptr: ?*anyopaque = null;
  if (remove) {
    if (c.napi_remove_wrap(env, value, &ptr) != c.napi_ok) {
      _ = c.napi_throw_error(env, null, "failed to remove object wrap");
      return Error.Exception;
    }
  } else {
    if (c.napi_unwrap(env, value, &ptr) != c.napi_ok) {
      _ = c.napi_throw_error(env, null, "failed to unwrap object");
      return Error.Exception;
    }
  }
  
  if (ptr == null) {
    _ = c.napi_throw_error(env, null, "unwraped null object");
    return Error.Exception;
  }

  return @ptrCast(*T, @alignCast(@alignOf(T), ptr));
}

fn CallbackInfo(comptime N: usize) type {
  return struct {
    thisArg: c.napi_value,
    argv: [N]c.napi_value,
  };
}

fn parseCallbackInfo(comptime N: usize, env: c.napi_env, info: c.napi_callback_info) Error!CallbackInfo(N) {
  var argv: [N]c.napi_value = undefined;
  var argc = N;
  var thisArg: c.napi_value = undefined;
  if (c.napi_get_cb_info(env, info, &argc, if (N == 0) null else &argv, &thisArg, null) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to get callback info");
    return Error.Exception;
  }

  if (argc != N) {
    _ = c.napi_throw_error(env, null, "expected {d} arguments, received {d}");
    return Error.Exception;
  }

  return CallbackInfo(N){ .thisArg = thisArg, .argv = argv };
}

fn parseStringAlloc(env: c.napi_env, value: c.napi_value) ![:0]u8 {
  var length: usize = 0;
  switch (c.napi_get_value_string_utf8(env, value, null, 0, &length)) {
    c.napi_ok => {},
    c.napi_string_expected => {
      _ = c.napi_throw_type_error(env, null, "string expected");
      return Error.Exception;
    },
    else => {
      _ = c.napi_throw_error(env, null, "failed to get string value");
      return Error.Exception;
    },
  }

  const buffer = try allocator.alloc(u8, length + 1);
  switch (c.napi_get_value_string_utf8(env, value, buffer.ptr, buffer.len, &length)) {
    c.napi_ok => {},
    c.napi_string_expected => {
      _ = c.napi_throw_type_error(env, null, "expected a string");
      return Error.Exception;
    },
    else => {
      _ = c.napi_throw_error(env, null, "failed to get string value");
      return Error.Exception;
    },
  }

  return buffer[0..length :0];
}

fn parseBuffer(env: c.napi_env, comptime N: usize, value: c.napi_value) !*const [N]u8 {
  var length: usize = 0;
  var ptr: ?*anyopaque = undefined;
  if (c.napi_get_buffer_info(env, value, &ptr, &length) != c.napi_ok) {
    _ = c.napi_throw_type_error(env, null, "expected a NodeJS Buffer");
    return Error.Exception;
  } else if (length != N) {
    _ = c.napi_throw_error(env, null, "buffer must be exactly N bytes");
    return Error.Exception;
  }

  return @ptrCast(*const [N]u8, ptr);
}

fn createBuffer(env: c.napi_env, buffer: []const u8) !c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_create_buffer_copy(env, buffer.len, buffer.ptr, null, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create buffer");
    return Error.Exception;
  }

  return result;
}

fn createObject(env: c.napi_env) !c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_create_object(env, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create object");
    return Error.Exception;
  }

  return result;
}

fn createString(env: c.napi_env, value: []const u8) !c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_create_string_utf8(env, value.ptr, value.len, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create string");
    return Error.Exception;
  }

  return result;
}

fn setProperty(env: c.napi_env, object: c.napi_value, key: []const u8, value: c.napi_value) !void {
  const keyString = try createString(env, key);
  if (c.napi_set_property(env, object, keyString, value) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to set property");
    return Error.Exception;
  }
}

fn setElement(env: c.napi_env, array: c.napi_value, index: u32, value: c.napi_value) !void {
  if (c.napi_set_element(env, array, index, value) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to set element");
    return Error.Exception;
  }
}

fn parseUint32(env: c.napi_env, value: c.napi_value) !u32 {
  var result: u32 = 0;
  switch (c.napi_get_value_uint32(env, value, &result)) {
    c.napi_ok => return result,
    c.napi_number_expected => {
      _ = c.napi_throw_type_error(env, null, "expected an unsigned integer");
      return Error.Exception;
    },
    else => {
      _ = c.napi_throw_error(env, null, "failed to get unsigned integer value");
      return Error.Exception;
    }
  }
}

fn typeOf(env: c.napi_env, value: c.napi_value) !c.napi_valuetype {
  var valueType: c.napi_valuetype = undefined;
  if (c.napi_typeof(env, value, &valueType) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to get type of value");
    return Error.Exception;
  }

  return valueType;
}