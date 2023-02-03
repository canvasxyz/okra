const std = @import("std");
const c = @import("./c.zig");

pub fn Callback(comptime argc: usize) type {
    return *const fn (env: c.napi_env, this: c.napi_value, args: *const [argc]c.napi_value) anyerror!c.napi_value;
}

fn Catch(comptime N: usize, comptime f: Callback(N)) type {
    return struct {
        fn throw(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
            var argv: [N]c.napi_value = undefined;
            var argc: usize = N;
            var this: c.napi_value = undefined;
            if (c.napi_get_cb_info(env, info, &argc, if (N == 0) null else &argv, &this, null) != c.napi_ok) {
                _ = c.napi_throw_error(env, null, "failed to get callback info");
                return null;
            }

            if (argc != N) {
                const error_message = std.fmt.bufPrintZ(&error_message_buffer, "expected {d} arguments, received {d}", .{ N, argc }) catch return null;
                _ = c.napi_throw_error(env, null, error_message.ptr);
                return null;
            }

            return f(env, this, &argv) catch |err| {
                if (err != Error.Exception) {
                    const name = @errorName(err);
                    _ = c.napi_throw_error(env, null, name.ptr);
                }

                return null;
            };
        }
    };
}

pub fn createMethod(comptime name: [*:0]const u8, comptime N: usize, comptime callback: Callback(N)) Method {
    return Method{
        .name = name,
        .callback = Catch(N, callback).throw,
    };
}

pub const Method = struct {
    name: [*:0]const u8,
    callback: *const fn (c.napi_env, c.napi_callback_info) callconv(.C) c.napi_value,
};

const Error = error{Exception};

pub fn defineClass(
    comptime name: [*:0]const u8,
    comptime argc: usize,
    comptime constructor: Callback(argc),
    comptime methods: []const Method,
    env: c.napi_env,
    exports: c.napi_value,
) Error!void {
    var properties: [methods.len]c.napi_property_descriptor = undefined;
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

    const wrappedConstructor = Catch(argc, constructor);

    var class_value: c.napi_value = undefined;
    if (c.napi_define_class(env, name, c.NAPI_AUTO_LENGTH, &wrappedConstructor.throw, null, properties.len, &properties, &class_value) != c.napi_ok) {
        _ = c.napi_throw_error(env, null, "failed to define class");
        return Error.Exception;
    }

    if (c.napi_set_named_property(env, exports, name, class_value) != c.napi_ok) {
        _ = c.napi_throw_error(env, null, "failed to add class constructor to exports");
        return Error.Exception;
    }
}

pub fn wrap(
    comptime T: type,
    env: c.napi_env,
    value: c.napi_value,
    ptr: *T,
    comptime destructor: fn (c.napi_env, ?*anyopaque, ?*anyopaque) callconv(.C) void,
    tag: *const c.napi_type_tag,
) Error!void {
    if (c.napi_wrap(env, value, ptr, destructor, null, null) != c.napi_ok) {
        return throwError(env, "failed to wrap object");
    } else if (c.napi_type_tag_object(env, value, tag) != c.napi_ok) {
        return throwError(env, "failed to tag object type");
    }
}

pub fn unwrap(comptime T: type, tag: *const c.napi_type_tag, env: c.napi_env, value: c.napi_value) Error!*T {
    var is_tag = false;
    if (c.napi_check_object_type_tag(env, value, tag, &is_tag) != c.napi_ok) {
        return throwError(env, "failed to check object type tag");
    } else if (!is_tag) {
        return throwTypeError(env, "invalid object type tag");
    }

    var ptr: ?*anyopaque = null;
    if (c.napi_unwrap(env, value, &ptr) != c.napi_ok) {
        return throwError(env, "failed to unwrap object");
    }

    if (ptr == null) {
        return throwError(env, "unwraped null object");
    }

    return @ptrCast(*T, @alignCast(@alignOf(T), ptr));
}

var error_message_buffer: [36]u8 = undefined;

pub fn parseBoolean(env: c.napi_env, value: c.napi_value) Error!bool {
    var result: bool = undefined;
    return switch (c.napi_get_value_bool(env, value, &result)) {
        c.napi_ok => result,
        c.napi_boolean_expected => throwTypeError(env, "expected a boolean"),
        else => throwError(env, "failed to get boolean value"),
    };
}

pub fn parseUint32(env: c.napi_env, value: c.napi_value) Error!u32 {
    var result: u32 = 0;
    return switch (c.napi_get_value_uint32(env, value, &result)) {
        c.napi_ok => result,
        c.napi_number_expected => throwTypeError(env, "expected an unsigned integer"),
        else => throwError(env, "failed to get unsigned integer value"),
    };
}

pub fn parseStringAlloc(env: c.napi_env, value: c.napi_value, allocator: std.mem.Allocator) ![:0]const u8 {
    var length: usize = 0;
    try switch (c.napi_get_value_string_utf8(env, value, null, 0, &length)) {
        c.napi_ok => {},
        c.napi_string_expected => throwTypeError(env, "expected a string"),
        else => throwError(env, "failed to get string length"),
    };

    const buffer = try allocator.alloc(u8, length + 1);
    try switch (c.napi_get_value_string_utf8(env, value, buffer.ptr, buffer.len, &length)) {
        c.napi_ok => {},
        c.napi_string_expected => throwTypeError(env, "expected a string"),
        else => throwError(env, "failed to get string value"),
    };

    return buffer[0..length :0];
}

pub fn parseBuffer(env: c.napi_env, value: c.napi_value) Error![]const u8 {
    var length: usize = 0;
    var ptr: ?*anyopaque = undefined;
    var is_buffer = false;
    if (c.napi_is_buffer(env, value, &is_buffer) != c.napi_ok) {
        return throwError(env, "failed to check buffer type");
    } else if (!is_buffer) {
        return throwTypeError(env, "expected a NodeJS Buffer");
    } else if (c.napi_get_buffer_info(env, value, &ptr, &length) != c.napi_ok) {
        return throwError(env, "failed to get buffer info");
    }

    return @ptrCast([*]const u8, ptr)[0..length];
}

pub fn createBoolean(env: c.napi_env, value: bool) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_get_boolean(env, value, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to create boolean"),
    };
}

pub fn createUint32(env: c.napi_env, value: u32) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_create_uint32(env, value, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to create unsigned integer"),
    };
}

pub fn createBuffer(env: c.napi_env, buffer: []const u8) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_create_buffer_copy(env, buffer.len, buffer.ptr, null, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to create buffer"),
    };
}

pub fn createObject(env: c.napi_env) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_create_object(env, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to create object"),
    };
}

pub fn createArray(env: c.napi_env) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_create_array(&result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to create array"),
    };
}

pub fn createArrayWithLength(env: c.napi_env, length: usize) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_create_array_with_length(env, length, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to create array"),
    };
}

pub fn createString(env: c.napi_env, value: []const u8) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_create_string_utf8(env, value.ptr, value.len, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to create string"),
    };
}

pub fn getProperty(env: c.napi_env, object: c.napi_value, key: c.napi_value) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_get_property(env, object, key, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to get object property"),
    };
}

pub fn setProperty(env: c.napi_env, object: c.napi_value, key: c.napi_value, value: c.napi_value) Error!void {
    try switch (c.napi_set_property(env, object, key, value)) {
        c.napi_ok => {},
        else => throwError(env, "failed to set object property"),
    };
}

pub fn setElement(env: c.napi_env, array: c.napi_value, index: u32, value: c.napi_value) Error!void {
    try switch (c.napi_set_element(env, array, index, value)) {
        c.napi_ok => {},
        else => throwError(env, "failed to set array element"),
    };
}

pub fn getLength(env: c.napi_env, array: c.napi_value) Error!u32 {
    var result: u32 = undefined;
    return switch (c.napi_get_array_length(env, array, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to get array length"),
    };
}

pub fn getElement(env: c.napi_env, array: c.napi_value, index: u32) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_get_element(env, array, index, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to get array element"),
    };
}

pub fn typeOf(env: c.napi_env, value: c.napi_value) Error!c.napi_valuetype {
    var result: c.napi_valuetype = undefined;
    return switch (c.napi_typeof(env, value, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to get type of value"),
    };
}

pub fn getUndefined(env: c.napi_env) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_get_undefined(env, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to get undefined"),
    };
}

pub fn getNull(env: c.napi_env) Error!c.napi_value {
    var result: c.napi_value = undefined;
    return switch (c.napi_get_null(env, &result)) {
        c.napi_ok => result,
        else => throwError(env, "failed to get null"),
    };
}

pub fn wrapArray(env: c.napi_env, elements: []c.napi_value) Error!c.napi_value {
    const result = try createArrayWithLength(env, elements.len);
    for (elements) |element, i| {
        try setElement(env, result, @intCast(u32, i), element);
    }

    return result;
}

pub fn throwError(env: c.napi_env, comptime message: [*:0]const u8) Error {
    _ = c.napi_throw_error(env, null, message);
    return Error.Exception;
}

pub fn throwTypeError(env: c.napi_env, comptime message: [*:0]const u8) Error {
    _ = c.napi_throw_type_error(env, null, message);
    return Error.Exception;
}

pub fn throwRangeError(env: c.napi_env, comptime message: [*:0]const u8) Error {
    _ = c.napi_throw_range_error(env, null, message);
    return Error.Exception;
}
