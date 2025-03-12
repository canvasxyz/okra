const std = @import("std");

const lmdb = @import("lmdb");
const Error = @import("error.zig").Error;

pub fn Cursor(comptime K: u8, comptime Q: u32) type {
    const Header = @import("Header.zig").Header(K, Q);
    const Node = @import("Node.zig").Node(K, Q);
    const Encoder = @import("encoder.zig").Encoder(K, Q);

    return struct {
        const Self = @This();

        level: u8 = 0xFF,
        cursor: lmdb.Cursor,
        encoder: Encoder,

        pub fn init(allocator: std.mem.Allocator, db: lmdb.Database) Error!Self {
            const cursor = try db.cursor();

            return .{
                .level = 0xFF,
                .cursor = cursor,
                .encoder = Encoder.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.encoder.deinit();
            self.cursor.deinit();
        }

        pub fn goToRoot(self: *Self) Error!Node {
            try self.cursor.goToKey(&Header.METADATA_KEY);
            if (try self.cursor.goToPrevious()) |root| {
                if (root.len != 1) {
                    return error.InvalidDatabase;
                }

                self.level = root[0];
                return try self.getCurrentNode();
            }

            return error.InvalidDatabase;
        }

        pub fn goToNode(self: *Self, level: u8, key: ?[]const u8) Error!void {
            const entry_key = try self.encoder.encodeKey(level, key);
            try self.cursor.goToKey(entry_key);
            self.level = level;
        }

        pub fn goToNext(self: *Self) Error!?Node {
            if (self.level == 0xFF) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToNext()) |entry_key| {
                if (entry_key.len == 0) {
                    return error.InvalidDatabase;
                } else if (entry_key[0] == self.level) {
                    return try self.getCurrentNode();
                }
            }

            self.level = 0xFF;
            return null;
        }

        pub fn goToPrevious(self: *Self) Error!?Node {
            if (self.level == 0xFF) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToPrevious()) |entry_key| {
                if (entry_key.len == 0) {
                    return error.InvalidDatabase;
                } else if (entry_key[0] == self.level) {
                    return try self.getCurrentNode();
                } else {
                    self.level = 0xFF;
                }
            }

            return null;
        }

        pub fn seek(self: *Self, level: u8, key: ?[]const u8) Error!?Node {
            const entry_key = try self.encoder.encodeKey(level, key);

            if (try self.cursor.seek(entry_key)) |needle| {
                if (needle.len == 0) {
                    return error.InvalidDatabase;
                }

                self.level = level;
                if (needle[0] == level) {
                    return try self.getCurrentNode();
                } else {
                    return null;
                }
            }

            return error.InvalidDatabase;
        }

        pub fn getCurrentNode(self: Self) Error!Node {
            if (self.level == 0xFF) {
                return error.Uninitialized;
            }

            const entry = try self.cursor.getCurrentEntry();
            return try Node.parse(entry.key, entry.value);
        }
    };
}
