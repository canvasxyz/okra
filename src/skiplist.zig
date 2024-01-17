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
        cursor: lmdb.Cursor,
        buffer: std.ArrayList(u8),
        logger: ?std.fs.File.Writer,
        effects: ?*Effects,

        pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, options: Options) !Self {
            try Header.initialize(db);
            const cursor = try db.cursor();
            return .{
                .allocator = allocator,
                .db = db,
                .cursor = cursor,
                .buffer = std.ArrayList(u8).init(allocator),
                .logger = options.log,
                .effects = options.effects,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cursor.deinit();
            self.buffer.deinit();
        }

        pub fn get(self: *Self, key: []const u8) !?[]const u8 {
            try self.buffer.resize(1 + key.len);
            self.buffer.items[0] = 0;
            @memcpy(self.buffer.items[1..], key);

            if (try self.db.get(self.buffer.items)) |value| {
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
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            if (self.effects) |effects| effects.reset();

            const allocator = arena.allocator();

            var operations = std.ArrayList(Effect).init(allocator);

            try self.print();

            const leaf_key = try Key.create(allocator, 0, op.key);

            // Handle the level 0 edits manually
            if (op.value) |new_value| {
                const new_leaf_value = try allocator.alloc(u8, K + new_value.len);
                Entry.hash(op.key, new_value, new_leaf_value[0..K]);
                // std.crypto.hash.Blake3.hash(new_value, new_leaf_value[0..K], .{});
                @memcpy(new_leaf_value[K..], new_value);

                if (try self.db.get(leaf_key)) |old_leaf_value| {
                    if (old_leaf_value.len < K) {
                        return error.InvalidDatabase;
                    } else if (std.mem.eql(u8, new_leaf_value, old_leaf_value)) {
                        return;
                    }

                    if (isBoundary(old_leaf_value[0..K])) {
                        const old_parent = try Key.create(allocator, 1, op.key);
                        if (isBoundary(new_leaf_value[0..K])) {
                            try self.db.set(leaf_key, new_leaf_value);
                            if (self.effects) |effects| effects.update += 1;

                            if (try self.db.get(old_parent) == null) {
                                try operations.append(.{ .create = old_parent });
                            } else {
                                try operations.append(.{ .update = old_parent });
                            }
                        } else {
                            try self.deleteNode(old_parent);

                            try self.db.set(leaf_key, new_leaf_value);
                            if (self.effects) |effects| effects.update += 1;

                            const new_parent = try self.getParent(allocator, leaf_key);
                            if (try self.db.get(new_parent) == null) {
                                try operations.append(.{ .create = new_parent });
                            } else {
                                try operations.append(.{ .update = new_parent });
                            }
                        }
                    } else {
                        const old_parent = try self.getParent(allocator, leaf_key);
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

        fn getParent(self: Self, allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
            if (key.len == 0) {
                return error.InternalError;
            }

            if (isAnchor(key)) {
                return try Key.create(allocator, key[0] + 1, null);
            }

            if (self.effects) |effects| effects.cursor_ops += 1;
            if (try self.cursor.seek(key)) |next| {
                try self.log("cursor.seek({s}) -> {s}\n", .{ hex(key), hex(next) });
                if (std.mem.eql(u8, next, key)) {
                    const value = try self.cursor.getCurrentValue();
                    if (value.len < K) {
                        return error.InvalidDatabase;
                    }

                    if (isBoundary(value[0..K])) {
                        return try Key.create(allocator, key[0] + 1, key[1..]);
                    }
                }
            } else {
                return error.InvalidDatabase;
            }

            if (self.effects) |effects| effects.cursor_ops += 1;
            while (try self.cursor.goToPrevious()) |previous| {
                if (previous.len == 0 or previous[0] != key[0]) {
                    return error.InvalidDatabase;
                } else if (isAnchor(previous)) {
                    return try Key.create(allocator, key[0] + 1, null);
                }

                const value = try self.cursor.getCurrentValue();
                if (value.len < K) {
                    return error.InvalidDatabase;
                } else if (isBoundary(value[0..K])) {
                    return try Key.create(allocator, previous[0] + 1, previous[1..]);
                }
            }

            return error.InvalidDatabase;
        }

        fn copy(self: *Self, value: []const u8) ![]u8 {
            try self.buffer.resize(value.len);
            @memcpy(self.buffer.items, value);
            return self.buffer.items;
        }

        fn getHash(self: *Self, parent: []const u8, result: *[K]u8) !void {
            var digest = std.crypto.hash.Blake3.init(.{});

            if (parent.len == 0 or parent[0] == 0) {
                return error.InternalError;
            }

            const first_child = try self.copy(parent);
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

        fn deleteNode(self: *Self, key: []const u8) !void {
            const target = try self.copy(key);

            while (try self.db.get(target)) |_| {
                try self.db.delete(target);
                if (self.effects) |effects| effects.delete += 1;

                target[0] += 1;
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
