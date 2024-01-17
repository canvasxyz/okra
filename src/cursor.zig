const std = @import("std");

const lmdb = @import("lmdb");

const Effects = @import("Effects.zig");

pub fn Cursor(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);
    const Node = @import("node.zig").Node(K, Q);
    const NodeList = @import("node_list.zig").NodeList(K, Q);
    const Encoder = @import("encoder.zig").Encoder(K, Q);

    return struct {
        const Self = @This();

        pub const Options = struct {
            effects: ?*Effects = null,
            trace: ?*NodeList = null,
        };

        level: u8 = 0xFF,
        cursor: lmdb.Cursor,
        encoder: Encoder,
        effects: ?*Effects = null,
        trace: ?*NodeList = null,

        pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, options: Options) !Self {
            const cursor = try db.cursor();
            return .{
                .level = 0xFF,
                .cursor = cursor,
                .encoder = Encoder.init(allocator),
                .effects = options.effects,
                .trace = options.trace,
            };
        }

        pub fn deinit(self: *Self) void {
            self.encoder.deinit();
            self.cursor.deinit();
        }

        pub fn goToRoot(self: *Self) !Node {
            if (self.effects) |effects| effects.cursor_ops += 1;

            try self.cursor.goToKey(&Header.METADATA_KEY);
            if (try self.cursor.goToPrevious()) |k| {
                if (k.len == 1) {
                    self.level = k[0];
                    return try self.getCurrentNode();
                }
            }

            return error.InvalidDatabase2;
        }

        pub fn goToNode(self: *Self, level: u8, key: ?[]const u8) !void {
            if (self.effects) |effects| effects.cursor_ops += 1;

            self.level = level;
            errdefer self.level = 0xFF;

            const k = try self.encoder.encodeKey(level, key);
            try self.cursor.goToKey(k);
        }

        pub fn goToNext(self: *Self) !?Node {
            if (self.effects) |effects| effects.cursor_ops += 1;

            if (self.level == 0xFF) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToNext()) |entry_key| {
                if (entry_key.len == 0) {
                    return error.InvalidDatabase3;
                } else if (entry_key[0] == self.level) {
                    return try self.getCurrentNode();
                } else {
                    self.level = 0xFF;
                }
            }

            return null;
        }

        pub fn goToPrevious(self: *Self) !?Node {
            if (self.effects) |effects| effects.cursor_ops += 1;

            if (self.level == 0xFF) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToPrevious()) |entry_key| {
                if (entry_key.len == 0) {
                    return error.InvalidDatabase4;
                } else if (entry_key[0] == self.level) {
                    return try self.getCurrentNode();
                } else {
                    self.level = 0xFF;
                }
            }

            return null;
        }

        pub fn seek(self: *Self, level: u8, key: ?[]const u8) !?Node {
            if (self.effects) |effects| effects.cursor_ops += 1;

            const entry_key = try self.encoder.encodeKey(level, key);
            if (try self.cursor.seek(entry_key)) |needle| {
                if (needle.len == 0) {
                    return error.InvalidDatabase5;
                } else if (needle[0] == level) {
                    self.level = level;
                    return try self.getCurrentNode();
                } else {
                    self.level = 0xFF;
                }
            }

            return null;
        }

        pub fn getCurrentNode(self: Self) !Node {
            const entry = try self.cursor.getCurrentEntry();
            return try Node.parse(entry.key, entry.value);
        }

        // pub fn setCurrentNode(self: Self, hash: *const [K]u8, value: ?[]const u8) !void {
        //     const entry_value = try self.encoder.encodeValue(hash, value);
        //     try self.cursor.setCurrentValue(entry_value);
        //     if (self.trace) |trace| {
        //         const node = try self.getCurrentNode();
        //         try trace.append(node);
        //     }
        // }

        // pub fn deleteCurrentNode(self: *Self) !void {
        //     try self.cursor.deleteCurrentKey();
        //     if (self.effects) |effects| effects.delete += 1;
        // }
    };
}
