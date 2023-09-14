const std = @import("std");
const expectEqual = std.testing.expectEqual;

const lmdb = @import("lmdb");
const Effects = @import("effects.zig");

pub fn Cursor(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);
    const Node = @import("node.zig").Node(K, Q);
    const NodeList = @import("node_list.zig").NodeList(K, Q);
    const Encoder = @import("encoder.zig").Encoder(K, Q);

    return struct {
        const Self = @This();

        pub const Options = struct {
            dbi: ?lmdb.Transaction.DBI = null,
            effects: ?*Effects = null,
            trace: ?*NodeList = null,
        };

        is_open: bool = false,
        level: u8 = 0xFF,
        cursor: lmdb.Cursor,
        encoder: Encoder,
        effects: ?*Effects = null,
        trace: ?*NodeList = null,

        pub fn open(allocator: std.mem.Allocator, txn: lmdb.Transaction, options: Options) !Self {
            var self: Self = undefined;
            try self.init(allocator, txn, options);
            return self;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, txn: lmdb.Transaction, options: Options) !void {
            const cursor = try lmdb.Cursor.open(txn, options.dbi);
            self.is_open = true;
            self.level = 0xFF;
            self.cursor = cursor;
            self.encoder = Encoder.init(allocator);
            self.effects = options.effects;
            self.trace = options.trace;
        }

        pub fn close(self: *Self) void {
            if (self.is_open) {
                self.is_open = false;
                self.cursor.close();
                self.encoder.deinit();
            }
        }

        pub fn goToRoot(self: *Self) !Node {
            if (try self.cursor.seek(&Header.METADATA_KEY)) |_| {
                if (try self.cursor.goToPrevious()) |k| {
                    if (k.len == 1) {
                        self.level = k[0];
                        return try self.getCurrentNode();
                    }
                }
            }

            return error.InvalidDatabase;
        }

        pub fn goToNode(self: *Self, level: u8, key: ?[]const u8) !Node {
            errdefer self.level = 0xFF;
            self.level = level;

            const k = try self.encoder.encodeKey(level, key);
            try self.cursor.goToKey(k);
            return try self.getCurrentNode();
        }

        pub fn goToNext(self: *Self) !?Node {
            if (self.level == 0xFF) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToNext()) |k| {
                if (k.len == 0) {
                    return error.InvalidDatabase;
                } else if (k[0] == self.level) {
                    return try self.getCurrentNode();
                } else {
                    self.level = 0xFF;
                }
            }

            return null;
        }

        pub fn goToPrevious(self: *Self) !?Node {
            if (self.level == 0xFF) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToPrevious()) |k| {
                if (k.len == 0) {
                    return error.InvalidDatabase;
                } else if (k[0] == self.level) {
                    return try self.getCurrentNode();
                } else {
                    self.level = 0xFF;
                }
            }

            return null;
        }

        pub fn seek(self: *Self, level: u8, key: ?[]const u8) !?Node {
            const entry_key = try self.encoder.encodeKey(level, key);
            if (try self.cursor.seek(entry_key)) |k| {
                if (k.len == 0) {
                    return error.InvalidDatabase;
                } else if (k[0] == level) {
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

        pub fn setCurrentNode(self: Self, hash: *const [K]u8, value: ?[]const u8) !void {
            const entry_value = try self.encoder.encodeValue(hash, value);
            try self.cursor.setCurrentValue(entry_value);
            if (self.trace) |trace| {
                const node = try self.getCurrentNode();
                try trace.append(node);
            }
        }

        pub fn deleteCurrentNode(self: *Self) !void {
            try self.cursor.deleteCurrentKey();
            if (self.effects) |effects| effects.delete += 1;
        }
    };
}
