const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

const Error = @import("error.zig").Error;

const lmdb = @import("lmdb");

fn getFanoutDegree(comptime Q: u32) [4]u8 {
    var value: [4]u8 = .{ 0, 0, 0, 0 };
    std.mem.writeInt(u32, &value, Q, .big);
    return value;
}

pub const Mode = enum(u8) {
    Index = 0,
    Store = 1,
};

pub fn Header(comptime K: u8, comptime Q: u32) type {
    const mode_fields = comptime switch (@typeInfo(Mode)) {
        .@"enum" => |info| info.fields,
        else => @compileError("expected enum"),
    };

    return struct {
        pub const LEAF_ANCHOR_KEY = [1]u8{0x00};
        pub const METADATA_KEY = [1]u8{0xff};

        pub const DATABASE_VERSION = 0x03;

        pub fn initialize(db: lmdb.Database, mode: Mode) Error!void {
            if (try db.get(&METADATA_KEY)) |value| {
                _ = try validate(value, mode);
                return;
            }

            write(db, mode) catch |err| {
                switch (err) {
                    error.ACCES => {},
                    else => return err,
                }
            };
        }

        pub fn write(db: lmdb.Database, mode: Mode) Error!void {
            var leaf_anchor_hash: [K]u8 = undefined;
            Blake3.hash(&[0]u8{}, &leaf_anchor_hash, .{});
            try db.set(&LEAF_ANCHOR_KEY, &leaf_anchor_hash);

            var header: [11]u8 = undefined;
            @memcpy(header[0..4], "okra");
            header[4] = DATABASE_VERSION;
            header[5] = K;
            std.mem.writeInt(u32, header[6..10], Q, .big);
            header[10] = @intFromEnum(mode);
            try db.set(&METADATA_KEY, &header);
        }

        pub fn validate(value: []const u8, mode: ?Mode) Error!Mode {
            if (value.len < 11)
                return error.InvalidDatabase;
            if (!std.mem.eql(u8, value[0..4], "okra"))
                return error.InvalidDatabase;
            if (value[4] != DATABASE_VERSION)
                return error.InvalidVersion;
            if (value[5] != K)
                return error.InvalidMetadata;
            if (std.mem.readInt(u32, value[6..10], .big) != Q)
                return error.InvalidMetadata;
            if (mode) |mode_assert| {
                if (value[10] != @intFromEnum(mode_assert)) {
                    return error.InvalidMetadata;
                } else {
                    return mode_assert;
                }
            } else {
                inline for (mode_fields) |field| {
                    if (value[10] == field.value) return @enumFromInt(field.value);
                }

                return error.InvalidDatabase;
            }
        }
    };
}
