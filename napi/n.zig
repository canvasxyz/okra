const std = @import("std");
const c = @import("./c.zig");

pub const Callback = fn(c.napi_env, c.napi_callback_info) callconv(.C) c.napi_value;

pub const Method = struct {
  name: [*:0]const u8,
  callback: Callback,
}; 

pub const Error = error { Exception };

pub fn defineClass(
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

pub fn wrap(
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

pub fn unwrap(comptime T: type, tag: *const c.napi_type_tag, env: c.napi_env, value: c.napi_value, remove: bool) Error!*T {
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

pub fn CallbackInfo(comptime N: usize) type {
  return struct {
    thisArg: c.napi_value,
    argv: [N]c.napi_value,
  };
}

pub fn parseCallbackInfo(comptime N: usize, env: c.napi_env, info: c.napi_callback_info) Error!CallbackInfo(N) {
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

pub fn parseStringAlloc(env: c.napi_env, value: c.napi_value, allocator: std.mem.Allocator) ![:0]u8 {
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

pub fn parseBuffer(env: c.napi_env, comptime N: usize, value: c.napi_value) !*const [N]u8 {
  var length: usize = 0;
  var ptr: ?*anyopaque = undefined;
  var isBuffer = false;
  if (c.napi_is_buffer(env, value, &isBuffer) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to check buffer type");
    return Error.Exception;
  } else if (!isBuffer) {
    _ = c.napi_throw_type_error(env, null, "expected a NodeJS Buffer");
    return Error.Exception;
  } else if (c.napi_get_buffer_info(env, value, &ptr, &length) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to get buffer info");
    return Error.Exception;
  } else if (length != N) {
    _ = c.napi_throw_error(env, null, "buffer must be exactly N bytes");
    return Error.Exception;
  }

  return @ptrCast(*const [N]u8, ptr);
}

pub fn createBuffer(env: c.napi_env, buffer: []const u8) !c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_create_buffer_copy(env, buffer.len, buffer.ptr, null, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create buffer");
    return Error.Exception;
  }

  return result;
}

pub fn createObject(env: c.napi_env) !c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_create_object(env, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create object");
    return Error.Exception;
  }

  return result;
}

pub fn createArray(env: c.napi_env) !c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_create_array(&result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create array");
    return Error.Exception;
  }

  return result;
}

pub fn createArrayWithLength(env: c.napi_env, length: usize) !c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_create_array_with_length(env, length, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create array");
    return Error.Exception;
  }

  return result;
}

pub fn createString(env: c.napi_env, value: []const u8) !c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_create_string_utf8(env, value.ptr, value.len, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to create string");
    return Error.Exception;
  }

  return result;
}

pub fn getProperty(env: c.napi_env, object: c.napi_value, key: c.napi_value) !c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_get_property(env, object, key, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to get property");
    return Error.Exception;
  }

  return result;
}

pub fn setProperty(env: c.napi_env, object: c.napi_value, key: c.napi_value, value: c.napi_value) !void {
  if (c.napi_set_property(env, object, key, value) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to set property");
    return Error.Exception;
  }
}

pub fn setElement(env: c.napi_env, array: c.napi_value, index: u32, value: c.napi_value) !void {
  if (c.napi_set_element(env, array, index, value) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to set element");
    return Error.Exception;
  }
}

pub fn getElement(env: c.napi_env, array: c.napi_value, index: u32) !c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_get_element(env, array, index, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to get element");
    return Error.Exception;
  }

  return result;
}

pub fn parseUint32(env: c.napi_env, value: c.napi_value) !u32 {
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

pub fn typeOf(env: c.napi_env, value: c.napi_value) !c.napi_valuetype {
  var valueType: c.napi_valuetype = undefined;
  if (c.napi_typeof(env, value, &valueType) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to get type of value");
    return Error.Exception;
  }

  return valueType;
}

pub fn getUndefined(env: c.napi_env) Error!c.napi_value {
  var result: c.napi_value = undefined;
  if (c.napi_get_undefined(env, &result) != c.napi_ok) {
    _ = c.napi_throw_error(env, null, "failed to get undefined");
    return Error.Exception;
  }

  return result;
}