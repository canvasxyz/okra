const std = @import("std");
const expectEqual = std.testing.expectEqual;

const lmdb = @import("lmdb");

pub fn Iterator(comptime K: u8, comptime Q: u32) type {
    const Node = @import("node.zig").Node(K, Q);
    const Tree = @import("tree.zig").Tree(K, Q);

    return struct {
        pub const Bound = struct { key: ?[]const u8, inclusive: bool };
        pub const Range = struct {
            level: u8 = 0,
            lower_bound: ?Bound = null,
            upper_bound: ?Bound = null,
            reverse: bool = false,
        };

        const Self = @This();

        allocator: std.mem.Allocator,
        is_open: bool = false,
        is_live: bool = false,
        is_done: bool = false,
        cursor: lmdb.Cursor,

        level: u8,
        lower_bound: std.ArrayList(u8),
        upper_bound: std.ArrayList(u8),
        lower_bound_inclusive: bool,
        upper_bound_inclusive: bool,
        reverse: bool,

        pub fn open(allocator: std.mem.Allocator, tree: *const Tree, range: Range) !Self {
            var iterator: Self = undefined;
            try iterator.init(allocator, tree, range);
            return iterator;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, tree: *const Tree, range: Range) !void {
            const cursor = try lmdb.Cursor.open(tree.db);
            self.allocator = allocator;
            self.lower_bound = std.ArrayList(u8).init(allocator);
            self.upper_bound = std.ArrayList(u8).init(allocator);
            self.is_open = true;
            self.cursor = cursor;
            try self.reset(range);
        }

        pub fn close(self: *Self) void {
            if (self.is_open) {
                self.is_open = false;
                self.is_live = false;
                self.is_done = true;
                self.cursor.close();
                self.lower_bound.deinit();
                self.upper_bound.deinit();
            }
        }

        pub fn reset(self: *Self, range: Range) !void {
            if (self.is_open) {
                self.is_live = false;
                self.is_done = false;
                self.level = range.level;
                self.reverse = range.reverse;

                if (range.lower_bound) |bound| {
                    try Self.copy(&self.lower_bound, range.level, bound.key);
                    self.lower_bound_inclusive = bound.inclusive;
                } else {
                    try Self.copy(&self.lower_bound, range.level, null);
                    self.lower_bound_inclusive = true;
                }

                if (range.upper_bound) |bound| {
                    try Self.copy(&self.upper_bound, range.level, bound.key);
                    self.upper_bound_inclusive = bound.inclusive;
                } else {
                    try Self.copy(&self.upper_bound, range.level + 1, null);
                    self.upper_bound_inclusive = false;
                }
            }
        }

        pub fn next(self: *Self) !?Node {
            if (self.is_done) return null;

            if (self.is_live) {
                if (self.reverse) {
                    return self.goToPrevious();
                } else {
                    return self.goToNext();
                }
            } else {
                self.is_live = true;
                if (self.reverse) {
                    return self.goToLast();
                } else {
                    return self.goToFirst();
                }
            }
        }

        inline fn goToFirst(self: *Self) !?Node {
            if (try self.cursor.seek(self.lower_bound.items)) |key| {
                if (self.isBelowUpperBound(key)) {
                    if (self.lower_bound_inclusive or std.mem.lessThan(u8, self.lower_bound.items, key)) {
                        const value = try self.cursor.getCurrentValue();
                        return try Node.parse(key, value);
                    } else {
                        return try self.goToNext();
                    }
                }
            }

            self.is_done = true;
            return null;
        }

        inline fn goToLast(self: *Self) !?Node {
            if (try self.cursor.seek(self.upper_bound.items)) |key| {
                if (self.isAboveLowerBound(key)) {
                    if (self.upper_bound_inclusive and std.mem.eql(u8, key, self.upper_bound.items)) {
                        const value = try self.cursor.getCurrentValue();
                        return try Node.parse(key, value);
                    } else {
                        return try self.goToPrevious();
                    }
                }
            }

            self.is_done = true;
            return null;
        }

        inline fn goToNext(self: *Self) !?Node {
            if (try self.cursor.goToNext()) |key| {
                if (self.isBelowUpperBound(key)) {
                    const value = try self.cursor.getCurrentValue();
                    return try Node.parse(key, value);
                }
            }

            self.is_done = true;
            return null;
        }

        inline fn goToPrevious(self: *Self) !?Node {
            if (try self.cursor.goToPrevious()) |key| {
                if (self.isAboveLowerBound(key)) {
                    const value = try self.cursor.getCurrentValue();
                    return try Node.parse(key, value);
                }
            }

            self.is_done = true;
            return null;
        }

        inline fn isAboveLowerBound(self: *Self, key: []const u8) bool {
            if (self.lower_bound_inclusive) {
                if (std.mem.lessThan(u8, key, self.lower_bound.items)) {
                    return false;
                }
            } else {
                if (!std.mem.lessThan(u8, self.lower_bound.items, key)) {
                    return false;
                }
            }

            return true;
        }

        inline fn isBelowUpperBound(self: *Self, key: []const u8) bool {
            if (self.upper_bound_inclusive) {
                if (std.mem.lessThan(u8, self.upper_bound.items, key)) {
                    return false;
                }
            } else {
                if (!std.mem.lessThan(u8, key, self.upper_bound.items)) {
                    return false;
                }
            }

            return true;
        }

        inline fn copy(buffer: *std.ArrayList(u8), level: u8, key: ?[]const u8) !void {
            if (key) |bytes| {
                try buffer.resize(1 + bytes.len);
                buffer.items[0] = level;
                std.mem.copy(u8, buffer.items[1..], bytes);
            } else {
                try buffer.resize(1);
                buffer.items[0] = level;
            }
        }
    };
}
