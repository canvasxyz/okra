const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const Effects = @import("Effects.zig");
const Logger = @import("Logger.zig");
const BufferPool = @import("BufferPool.zig");
const Entry = @import("Entry.zig");
const Key = @import("Key.zig");

const nil = [0]u8{};

pub fn SkipList(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);
    const Node = @import("node.zig").Node(K, Q);
    const Encoder = @import("encoder.zig").Encoder(K, Q);
    const Cursor = @import("cursor.zig").Cursor(K, Q);

    return struct {
        const Self = @This();

        const Operation = struct { key: []const u8, value: ?[]const u8 };

        const EffectType = enum { create, update };
        const Effect = union(EffectType) {
            create: []const u8,
            update: []const u8,
        };

        pub const Options = struct {
            log: ?std.fs.File.Writer = null,
            effects: ?*Effects = null,
        };

        allocator: std.mem.Allocator,
        db: lmdb.Database,
        cursor: Cursor,
        encoder: Encoder,

        // key_buffer: std.ArrayList(u8),
        // buffer: std.ArrayList(u8),
        logger: ?std.fs.File.Writer,
        effects: ?*Effects,

        pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, options: Options) !Self {
            try Header.initialize(db);

            const cursor = try Cursor.init(allocator, db, .{ .effects = options.effects });

            return .{
                .allocator = allocator,
                .db = db,
                .cursor = cursor,
                .encoder = Encoder.init(allocator),
                // .key_buffer = std.ArrayList(u8).init(allocator),
                // .buffer = std.ArrayList(u8).init(allocator),
                .logger = options.log,
                .effects = options.effects,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cursor.deinit();
            self.encoder.deinit();

            // self.buffer.deinit();
            // self.key_buffer.deinit();
        }

        pub fn get(self: *Self, key: []const u8) !?[]const u8 {
            if (try self.getNode(0, key)) |value| {
                if (value.len < K) {
                    return error.InvalidDatabase;
                } else {
                    return value[K..];
                }
            } else {
                return null;
            }
        }

        pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
            try self.log("------------------------\n", .{});
            var hash: [K]u8 = undefined;
            std.crypto.hash.Blake3.hash(value, &hash, .{});
            try self.log("set({s}, {s}) [{any}]\n", .{ hex(key), hex(value), isBoundary(&hash) });
            try self.apply(.{ .key = key, .value = value });
            try self.log("------------------------\n", .{});
        }

        pub fn delete(self: *Self, key: []const u8) !void {
            try self.log("------------------------\n", .{});
            try self.log("delete({s})\n", .{hex(key)});
            try self.apply(.{ .key = key, .value = null });
            try self.log("------------------------\n", .{});
        }

        fn apply(self: *Self, op: Operation) !void {

            // var arena = std.heap.ArenaAllocator.init(self.allocator);
            // defer arena.deinit();

            // if (self.effects) |effects| effects.reset();

            // const allocator = arena.allocator();

            var operations = std.ArrayList(Effect).init(self.allocator);
            defer operations.deinit();

            try self.print();

            // Handle the level 0 edits manually
            if (op.value) |value| {
                var hash: [K]u8 = undefined;
                Entry.hash(op.key, value, &hash);
                const new_leaf = Node{ .level = 0, .key = op.key, .hash = &hash, .value = value };

                if (try self.getNode(0, op.key)) |old_leaf| {
                    const old_value = old_leaf.value orelse return error.InvalidDatabase;
                    if (std.mem.eql(u8, old_value, value)) {
                        return;
                    }

                    if (old_leaf.isBoundary()) {
                        if (new_leaf.isBoundary()) {
                            try self.setNode(new_leaf);
                            if (self.effects) |effects| effects.update += 1;

                            try operations.append(.{ .update = op.key });
                        } else {
                            try self.deleteNode(1, op.key);
                            try self.setNode(new_leaf);
                            if (self.effects) |effects| effects.update += 1;

                            // TODO: copy new_parent
                            const new_parent = try self.getParent(0, op.key);
                            if (try self.getNode(1, new_parent) == null) {
                                try operations.append(.{ .create = new_parent });
                            } else {
                                try operations.append(.{ .update = new_parent });
                            }
                        }
                    } else {
                        const old_parent = try self.getParent(0, new_leaf.key);
                        if (try self.db.get(old_parent) == null) {
                            try operations.append(.{ .create = old_parent });
                        } else {
                            try operations.append(.{ .update = old_parent });
                        }

                        try self.db.set(leaf_key, new_leaf_value);
                        if (self.effects) |effects| effects.update += 1;

                        if (isBoundary(new_leaf_value[0..K])) {
                            const new_parent = try Key.create(allocator, 1, op.key);
                            try operations.append(.{ .create = new_parent });
                        }
                    }
                } else {
                    const old_parent = try self.getParent(allocator, leaf_key);
                    try self.log("leaf_key: {s}\n", .{hex(leaf_key)});
                    try self.log("old_parent: {s}\n", .{hex(old_parent)});
                    if (try self.db.get(old_parent) == null) {
                        try operations.append(.{ .create = old_parent });
                    } else {
                        try operations.append(.{ .update = old_parent });
                    }

                    try self.db.set(leaf_key, new_leaf_value);
                    if (self.effects) |effects| effects.create += 1;

                    if (isBoundary(new_leaf_value[0..K])) {
                        const new_parent = try Key.create(allocator, 1, op.key);
                        try operations.append(.{ .create = new_parent });
                    }
                }
            } else {
                if (try self.db.get(leaf_key)) |old_leaf_value| {
                    if (old_leaf_value.len < K) {
                        return error.InvalidDatabase;
                    }

                    if (isBoundary(old_leaf_value[0..K])) {
                        const old_parent = try Key.create(allocator, 1, op.key);
                        try self.deleteNode(old_parent);

                        try self.db.delete(leaf_key);
                        if (self.effects) |effects| effects.delete += 1;

                        const new_parent = try self.getParent(allocator, leaf_key);
                        if (try self.db.get(new_parent) == null) {
                            try operations.append(.{ .create = new_parent });
                        } else {
                            try operations.append(.{ .update = new_parent });
                        }
                    } else {
                        const parent = try self.getParent(allocator, leaf_key);
                        if (try self.db.get(parent) == null) {
                            try operations.append(.{ .create = parent });
                        } else {
                            try operations.append(.{ .update = parent });
                        }

                        try self.db.delete(leaf_key);
                        if (self.effects) |effects| effects.delete += 1;
                    }
                } else {
                    return;
                }
            }

            var hash: [K]u8 = undefined;
            var level: u8 = 0;
            while (operations.items.len > 0) : (level += 1) {
                const initial_len = operations.items.len;

                try self.log("level {d}\n", .{level});
                try self.print();

                try self.log("{d} operations\n", .{operations.items.len});
                for (operations.items) |operation| {
                    switch (operation) {
                        .create => |key| try self.log("- create {s}\n", .{hex(key)}),
                        .update => |key| try self.log("- update {s}\n", .{hex(key)}),
                    }
                }
                // try self.log("------------\n", .{});

                for (operations.items, 0..) |operation, i| {
                    switch (operation) {
                        .update => |key| {
                            try self.log("update({s})\n", .{hex(key)});
                            try std.testing.expectEqual(0, i);
                            try std.testing.expectEqual(level + 1, key[0]);
                            // assert(key[0] == level);

                            const old_hash = try self.db.get(key) orelse return error.InvalidDatabase;
                            if (old_hash.len != K) {
                                return error.InvalidDatabase;
                            }

                            try self.getHash(key, &hash);

                            if (isAnchor(key)) {
                                try self.db.set(key, &hash);
                                if (self.effects) |effects| effects.update += 1;

                                if (try self.db.get(&.{key[0] + 1})) |_| {
                                    const parent = try Key.create(allocator, key[0] + 1, null);
                                    try operations.append(.{ .update = parent });
                                } else if (initial_len > 1) {
                                    const parent = try Key.create(allocator, key[0] + 1, null);
                                    try operations.append(.{ .create = parent });
                                }
                            } else if (isBoundary(old_hash[0..K])) {
                                const old_parent = try Key.create(allocator, key[0] + 1, key[1..]);
                                if (isBoundary(&hash)) {
                                    try operations.append(.{ .update = old_parent });
                                    try self.db.set(key, &hash);
                                    if (self.effects) |effects| effects.update += 1;
                                } else {
                                    try self.deleteNode(old_parent);
                                    try self.db.set(key, &hash);
                                    if (self.effects) |effects| effects.update += 1;

                                    const new_parent = try self.getParent(allocator, key);
                                    try operations.append(.{ .update = new_parent });
                                }
                            } else {
                                const old_parent = try self.getParent(allocator, key);
                                try operations.append(.{ .update = old_parent });
                                try self.db.set(key, &hash);
                                if (self.effects) |effects| effects.update += 1;

                                if (isBoundary(&hash)) {
                                    const new_parent = try Key.create(allocator, key[0] + 1, key[1..]);
                                    try operations.append(.{ .create = new_parent });
                                }
                            }
                        },
                        .create => |key| {
                            try self.log("create({s})\n", .{hex(key)});
                            // assert(key[0] == level);
                            try std.testing.expectEqual(level + 1, key[0]);

                            try self.getHash(key, &hash);

                            if (isAnchor(key)) {
                                if (initial_len > 1) {
                                    const parent = try Key.create(allocator, key[0] + 1, null);
                                    try operations.append(.{ .create = parent });
                                }
                            } else if (isBoundary(&hash)) {
                                const parent = try Key.create(allocator, key[0] + 1, key[1..]);
                                try operations.append(.{ .create = parent });
                            }

                            try self.db.set(key, &hash);
                            if (self.effects) |effects| effects.create += 1;
                        },
                    }
                }

                try operations.replaceRange(0, initial_len, &.{});
            }

            if (self.effects) |effects| effects.cursor_ops += 1;
            try self.cursor.goToKey(&.{level});

            if (self.effects) |effects| effects.cursor_ops += 1;
            while (try self.cursor.goToPrevious()) |key| {
                if (self.effects) |effects| effects.cursor_ops += 1;

                if (isAnchor(key)) {
                    try self.db.delete(&.{level});
                    if (self.effects) |effects| effects.delete += 1;

                    level -= 1;
                } else {
                    break;
                }
            }

            if (self.effects) |effects| effects.height = level + 1;
        }

        fn print(self: Self) !void {
            const cursor = try self.db.cursor();
            defer cursor.deinit();

            try self.log("------------\n", .{});

            if (try cursor.goToFirst()) |key| {
                const value = try cursor.getCurrentValue();
                try self.log("{s}\t{s}\n", .{ hex(key), hex(value) });
            }

            while (try cursor.goToNext()) |key| {
                const value = try cursor.getCurrentValue();
                if (std.mem.eql(u8, key, &Header.METADATA_KEY)) {
                    try self.log("{s}\t{s}\n", .{ hex(key), hex(value) });
                } else {
                    try self.log("{s}\t{s}\t[{any}]\n", .{ hex(key), hex(value), isBoundary(value[0..K]) });
                }
            }

            try self.log("------------\n", .{});
        }

        fn getParent(self: *Self, level: u8, key: ?[]const u8) !?[]const u8 {
            if (key == null) {
                return null;
            }

            if (try self.cursor.seek(level, key)) |next| {
                try self.log("cursor.seek({d}, {s}) -> {s}\n", .{ level, Key.fmt(key), Key.fmt(next.key) });
                if (Key.equal(next.key, key) and next.isBoundary()) {
                    return next.key;
                }
            } else {
                return error.InvalidDatabase;
            }

            while (try self.cursor.goToPrevious()) |previous| {
                if (previous.key == null or previous.isBoundary()) {
                    return previous.key;
                }
            }

            return error.InvalidDatabase;
        }

        fn getNode(self: *Self, level: u8, key: ?[]const u8) !?Node {
            const entry_key = self.encoder.encodeKey(level, key);
            if (try self.db.get(entry_key)) |entry_value| {
                return Node.parse(entry_key, entry_value);
            } else {
                return null;
            }
        }

        fn setNode(self: *Self, node: Node) !void {
            const entry = try self.encoder.encode(node);
            try self.db.set(entry.key, entry.value);
        }

        fn getHash(self: *Self, parent: []const u8, result: *[K]u8) !void {
            var digest = std.crypto.hash.Blake3.init(.{});

            if (parent.len == 0 or parent[0] == 0) {
                return error.InternalError;
            }

            const first_child = try self.encoder.encodeKey(parent[0], parent[1..]);
            first_child[0] = parent[0] - 1;

            {
                if (self.effects) |effects| effects.cursor_ops += 1;
                try self.cursor.goToKey(first_child);
                const value = try self.cursor.getCurrentValue();
                if (value.len < K) {
                    return error.InvalidDatabase;
                }

                digest.update(value[0..K]);
            }

            if (self.effects) |effects| effects.cursor_ops += 1;
            while (try self.cursor.goToNext()) |key| {
                if (self.effects) |effects| effects.cursor_ops += 1;
                if (key.len == 0) {
                    return error.InvalidDatabase;
                } else if (key[0] != first_child[0]) {
                    break;
                }

                const value = try self.cursor.getCurrentValue();
                if (value.len < K) {
                    return error.InvalidDatabase;
                } else if (isBoundary(value[0..K])) {
                    break;
                }

                digest.update(value[0..K]);
            }

            digest.final(result);
        }

        fn deleteNode(self: *Self, level: u8, key: ?[]const u8) !void {
            const entry_key = try self.encoder.encodeKey(level, key);
            while (try self.db.get(entry_key)) |_| {
                try self.db.delete(entry_key);
                if (self.effects) |effects| effects.delete += 1;

                entry_key[0] += 1;
            }
        }

        fn isAnchor(key: []const u8) bool {
            return key.len == 1;
        }

        fn isBoundary(hash: *const [K]u8) bool {
            const limit: comptime_int = (1 << 32) / @as(u33, @intCast(Q));
            return std.mem.readInt(u32, hash[0..4], .big) < limit;
        }

        fn log(self: Self, comptime format: []const u8, args: anytype) !void {
            if (self.logger) |writer| {
                try writer.print(format, args);
            }
        }
    };
}
