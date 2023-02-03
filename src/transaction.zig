const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const expectEqualSlices = std.testing.expectEqualSlices;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const utils = @import("utils.zig");
const print = @import("print.zig");

const Result = enum { update, delete };

const OperationTag = enum { set, delete };
const Operation = union(OperationTag) {
    set: struct { key: []const u8, value: []const u8 },
    delete: []const u8,
};

pub fn Transaction(comptime K: u8, comptime Q: u32) type {
    const Node = @import("node.zig").Node(K, Q);
    const Tree = @import("tree.zig").Tree(K, Q);
    const Header = @import("header.zig").Header(K, Q);
    const Logger = @import("logger.zig").Logger;
    const BufferPool = @import("buffer_pool.zig").BufferPool;

    return struct {
        const Self = @This();
        pub const Options = struct { read_only: bool, dbi: ?[*:0]const u8 = null, log: ?std.fs.File.Writer = null };

        allocator: std.mem.Allocator,
        open: bool = false,
        txn: lmdb.Transaction,
        cursor: lmdb.Cursor,

        value_buffer: std.ArrayList(u8),
        key_buffer: std.ArrayList(u8),
        hash_buffer: [K]u8,
        pool: BufferPool,
        new_siblings: std.ArrayList([]const u8),
        logger: Logger,

        pub fn open(allocator: std.mem.Allocator, tree: *const Tree, options: Options) !Self {
            var transaction: Self = undefined;
            try transaction.init(allocator, tree, options);
            return transaction;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, tree: *const Tree, options: Options) !void {
            if (options.dbi) |dbi| {
                if (!tree.dbs.contains(std.mem.span(dbi))) {
                    return error.DatabaseNotFound;
                }
            } else {
                if (tree.dbs.count() > 0) {
                    return error.DatabaseNotFound;
                }
            }

            const txn = try lmdb.Transaction.open(tree.env, .{ .read_only = options.read_only, .dbi = options.dbi });
            errdefer txn.abort();

            const cursor = try lmdb.Cursor.open(txn);
            errdefer cursor.close();

            try Header.validate(txn);

            self.allocator = allocator;
            self.open = true;
            self.txn = txn;
            self.cursor = cursor;
            self.pool = BufferPool.init(allocator);
            self.key_buffer = std.ArrayList(u8).init(allocator);
            self.value_buffer = std.ArrayList(u8).init(allocator);
            self.new_siblings = std.ArrayList([]const u8).init(allocator);
            self.logger = Logger.init(allocator, options.log);
        }

        pub fn abort(self: *Self) void {
            if (self.open) {
                defer self.deinit();
                self.txn.abort();
            }
        }

        pub fn commit(self: *Self) !void {
            if (self.open) {
                defer self.deinit();
                try self.txn.commit();
            } else {
                return error.TransactionClosed;
            }
        }

        fn deinit(self: *Self) void {
            self.open = false;
            self.pool.deinit();
            self.key_buffer.deinit();
            self.value_buffer.deinit();
            self.new_siblings.deinit();
            self.logger.deinit();
        }

        pub fn get(self: *Self, key: []const u8) !?[]const u8 {
            if (try self.getNode(0, key)) |node| {
                if (node.value == null) {
                    return error.InvalidDatabase;
                } else {
                    return node.value;
                }
            } else {
                return null;
            }
        }

        pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
            if (key.len == 0) {
                return error.InvalidKey;
            }

            try self.log("set({s}, {s})", .{ hex(key), hex(value) });
            try self.apply(Operation{ .set = .{ .key = key, .value = value } });
        }

        pub fn delete(self: *Self, key: []const u8) !void {
            if (key.len == 0) {
                return error.InvalidKey;
            }

            try self.log("delete({s})", .{hex(key)});
            try self.apply(Operation{ .delete = key });
        }

        fn apply(self: *Self, operation: Operation) !void {
            const root = try self.getRoot();
            try self.log("height: {d}", .{root.level});

            var root_level = if (root.level == 0) 1 else root.level;

            self.logger.reset();
            try self.new_siblings.resize(0);
            try self.pool.allocate(root_level - 1);

            const nil = [_]u8{};
            const result = try switch (root.level) {
                0 => self.applyLeaf(&nil, operation),
                else => self.applyNode(root_level - 1, &nil, operation),
            };

            try switch (result) {
                Result.update => {},
                Result.delete => error.InternalError,
            };

            _ = try self.hashNode(root_level, &nil);

            try self.log("new_children: {d}", .{self.new_siblings.items.len});
            for (self.new_siblings.items) |child| try self.log("- {s}", .{hex(child)});

            while (self.new_siblings.items.len > 0) {
                try self.promote(root_level);

                root_level += 1;
                _ = try self.hashNode(root_level, &nil);
                try self.log("new_children: {d}", .{self.new_siblings.items.len});
                for (self.new_siblings.items) |child| try self.log("- {s}", .{hex(child)});
            }

            try self.goToNode(root_level, &nil);
            while (root_level > 0) : (root_level -= 1) {
                const last_key = try self.goToLast(root_level - 1);
                if (last_key.len > 0) {
                    break;
                } else {
                    try self.log("trim root from {d} to {d}", .{ root_level, root_level - 1 });
                    try self.deleteNode(root_level, &nil);
                }
            }
        }

        fn applyLeaf(self: *Self, first_child: []const u8, operation: Operation) !Result {
            switch (operation) {
                .set => |entry| {
                    utils.hashEntry(entry.key, entry.value, &self.hash_buffer);
                    const leaf = Node{
                        .level = 0,
                        .key = entry.key,
                        .hash = &self.hash_buffer,
                        .value = entry.value,
                    };

                    try self.setNode(leaf);

                    if (std.mem.lessThan(u8, first_child, entry.key)) {
                        if (leaf.isSplit()) {
                            try self.new_siblings.append(entry.key);
                        }

                        return Result.update;
                    } else if (std.mem.eql(u8, first_child, entry.key)) {
                        if (first_child.len == 0 or leaf.isSplit()) {
                            return Result.update;
                        } else {
                            return Result.delete;
                        }
                    } else {
                        return error.InvalidDatabase;
                    }
                },
                .delete => |key| {
                    try self.deleteNode(0, key);
                    if (std.mem.eql(u8, key, first_child)) {
                        return Result.delete;
                    } else {
                        return Result.update;
                    }
                },
            }
        }

        fn applyNode(self: *Self, level: u8, first_child: []const u8, operation: Operation) !Result {
            if (first_child.len == 0) {
                try self.log("insertNode({d}, null)", .{level});
            } else {
                try self.log("insertNode({d}, {s})", .{ level, hex(first_child) });
            }

            try self.logger.indent();
            defer self.logger.deindent();

            if (level == 0) {
                return self.applyLeaf(first_child, operation);
            }

            const target = try switch (operation) {
                Operation.set => |entry| self.findTargetKey(level, first_child, entry.key),
                Operation.delete => |key| self.findTargetKey(level, first_child, key),
            };

            if (target.len == 0) {
                try self.log("target: null", .{});
            } else {
                try self.log("target: {s}", .{hex(target)});
            }

            const is_left_edge = first_child.len == 0;
            try self.log("is_left_edge: {any}", .{is_left_edge});

            const is_first_child = std.mem.eql(u8, target, first_child);
            try self.log("is_first_child: {any}", .{is_first_child});

            const result = try self.applyNode(level - 1, target, operation);
            switch (result) {
                Result.delete => try self.log("result: delete", .{}),
                Result.update => try self.log("result: update", .{}),
            }

            try self.log("new siblings: {d}", .{self.new_siblings.items.len});
            for (self.new_siblings.items) |child|
                try self.log("- {s}", .{hex(child)});

            switch (result) {
                Result.delete => {
                    assert(!is_left_edge or !is_first_child);

                    // delete the entry and move to the previous child
                    // previous_child is the slice at target_keys[level - 1].items
                    const previous_child = try self.moveToPreviousChild(level);
                    if (previous_child.len == 0) {
                        try self.log("previous_child: null", .{});
                    } else {
                        try self.log("previous_child: {s}", .{hex(previous_child)});
                    }

                    try self.promote(level);

                    const is_previous_child_split = try self.hashNode(level, previous_child);
                    if (is_first_child or std.mem.lessThan(u8, previous_child, first_child)) {
                        if (is_previous_child_split) {
                            try self.new_siblings.append(previous_child);
                        }

                        return Result.delete;
                    } else if (std.mem.eql(u8, previous_child, first_child)) {
                        if (is_left_edge or is_previous_child_split) {
                            return Result.update;
                        } else {
                            return Result.delete;
                        }
                    } else {
                        if (is_previous_child_split) {
                            try self.new_siblings.append(target);
                        }

                        return Result.update;
                    }
                },
                Result.update => {
                    const is_target_split = try self.hashNode(level, target);
                    try self.log("is_target_split: {any}", .{is_target_split});

                    try self.promote(level);

                    // is_first_child means either target's original value was a split, or is_left_edge is true.
                    if (is_first_child) {
                        if (is_target_split or is_left_edge) {
                            return Result.update;
                        } else {
                            return Result.delete;
                        }
                    } else {
                        if (is_target_split) {
                            try self.new_siblings.append(target);
                        }

                        return Result.update;
                    }
                },
            }
        }

        fn findTargetKey(self: *Self, level: u8, first_child: []const u8, key: []const u8) ![]const u8 {
            assert(level > 0);
            const id = level - 1;
            try self.pool.set(id, first_child);
            try self.goToNode(level, first_child);
            while (try self.goToNext(level)) |next_child| {
                if (std.mem.lessThan(u8, key, next_child)) {
                    break;
                } else {
                    try self.pool.set(id, next_child);
                }
            }

            return self.pool.get(id);
        }

        /// moveToPreviousChild operates on target_key (via its known location in the buffer pool)
        /// IN PLACE (ie it mutates the buffer pool value) and returns a new slice to its updated contents
        fn moveToPreviousChild(self: *Self, level: u8) ![]const u8 {
            assert(level > 0);
            const id = level - 1;

            // delete the entry and move to the previous child
            try self.goToNode(level, self.pool.get(id));

            try self.cursor.deleteCurrentKey();
            while (try self.goToPrevious(level)) |previous_child| {
                if (previous_child.len == 0) {
                    return try self.pool.copy(id, previous_child);
                } else if (try self.getNode(level - 1, previous_child)) |previous_grand_child| {
                    if (previous_grand_child.isSplit()) {
                        return try self.pool.copy(id, previous_child);
                    }
                }

                try self.cursor.deleteCurrentKey();
            }

            return error.InternalError;
        }

        /// Computes and sets the hash of the given node. Doesn't assume anything about the current cursor position.
        /// Returns is_split for the updated hash.
        fn hashNode(self: *Self, level: u8, key: []const u8) !bool {
            if (key.len == 0) {
                try self.log("hashNode({d}, null)", .{level});
            } else {
                try self.log("hashNode({d}, {s})", .{ level, hex(key) });
            }

            try self.goToNode(level - 1, key);
            var digest = Blake3.init(.{});

            {
                const node = try self.getCurrentNode();
                if (key.len == 0) {
                    try self.log("- hashing {s} <- null", .{hex(node.hash)});
                } else {
                    try self.log("- hashing {s} <- {s}", .{ hex(node.hash), hex(key) });
                }

                digest.update(node.hash);
            }

            while (try self.goToNext(level - 1)) |next_key| {
                const node = try self.getCurrentNode();
                if (node.isSplit()) {
                    break;
                } else {
                    try self.log("- hashing {s} <- {s}", .{ hex(node.hash), hex(next_key) });
                    digest.update(node.hash);
                }
            }

            digest.final(&self.hash_buffer);
            try self.log("--------- {s}", .{hex(&self.hash_buffer)});

            if (key.len == 0) {
                try self.log("setting {s} <- ({d}) null", .{ hex(&self.hash_buffer), level });
            } else {
                try self.log("setting {s} <- ({d}) {s}", .{ hex(&self.hash_buffer), level, hex(key) });
            }

            const node = Node{
                .level = level,
                .key = if (key.len == 0) null else key,
                .hash = &self.hash_buffer,
                .value = null,
            };

            try self.setNode(node);
            return node.isSplit();
        }

        fn promote(self: *Self, level: u8) !void {
            var old_index: usize = 0;
            var new_index: usize = 0;
            const new_sibling_count = self.new_siblings.items.len;
            while (old_index < new_sibling_count) : (old_index += 1) {
                const key = self.new_siblings.items[old_index];
                const is_split = try self.hashNode(level, key);
                if (is_split) {
                    self.new_siblings.items[new_index] = key;
                    new_index += 1;
                }
            }

            try self.new_siblings.resize(new_index);
        }

        fn setKey(self: *Self, level: u8, key: ?[]const u8) !void {
            if (key) |bytes| {
                try self.key_buffer.resize(1 + bytes.len);
                std.mem.copy(u8, self.key_buffer.items[1..], bytes);
            } else {
                try self.key_buffer.resize(1);
            }

            self.key_buffer.items[0] = level;
        }

        pub fn getRoot(self: *Self) !Node {
            try self.cursor.goToKey(&Header.HEADER_KEY);
            if (try self.cursor.goToPrevious()) |k| {
                const value = try self.cursor.getCurrentValue();
                if (k.len == 1 and value.len == K) {
                    return Node{ .level = k[0], .key = null, .hash = value[0..K], .value = null };
                }
            }

            return error.InvalidDatabase;
        }

        pub fn getNode(self: *Self, level: u8, key: ?[]const u8) !?Node {
            try self.setKey(level, key);
            if (try self.txn.get(self.key_buffer.items)) |value| {
                if (value.len < K) {
                    return error.InvalidDatabase;
                }

                return Node{
                    .level = level,
                    .key = if (key != null) self.key_buffer.items[1..] else null,
                    .hash = value[0..K],
                    .value = if (level == 0 and key != null) value[K..] else null,
                };
            } else {
                return null;
            }
        }

        fn setNode(self: *Self, node: Node) !void {
            try self.setKey(node.level, node.key);
            if (node.value) |value| {
                if (node.level != 0) {
                    return error.InternalError;
                }

                try self.value_buffer.resize(K + value.len);
                std.mem.copy(u8, self.value_buffer.items[0..K], node.hash);
                std.mem.copy(u8, self.value_buffer.items[K .. K + value.len], value);
            } else {
                if (node.level == 0) {
                    return error.InternalError;
                }

                try self.value_buffer.resize(K);
                std.mem.copy(u8, self.value_buffer.items, node.hash);
            }

            try self.txn.set(self.key_buffer.items, self.value_buffer.items);
        }

        fn deleteNode(self: *Self, level: u8, key: []const u8) !void {
            try self.setKey(level, key);
            try self.txn.delete(self.key_buffer.items);
        }

        fn goToNode(self: *Self, level: u8, key: []const u8) !void {
            try self.setKey(level, key);
            try self.cursor.goToKey(self.key_buffer.items);
        }

        fn goToNext(self: *Self, level: u8) !?[]const u8 {
            if (try self.cursor.goToNext()) |key| {
                if (key[0] == level) {
                    return key[1..];
                }
            }

            return null;
        }

        fn goToPrevious(self: *Self, level: u8) !?[]const u8 {
            if (try self.cursor.goToPrevious()) |key| {
                if (key[0] == level) {
                    return key[1..];
                }
            }

            return null;
        }

        fn goToLast(self: *Self, level: u8) ![]const u8 {
            try self.goToNode(level + 1, &[_]u8{});

            if (try self.cursor.goToPrevious()) |previous_key| {
                if (previous_key[0] == level) {
                    return previous_key[1..];
                }
            }

            return error.KeyNotFound;
        }

        fn getCurrentNode(self: *Self) !Node {
            const key = try self.cursor.getCurrentKey();
            const value = try self.cursor.getCurrentValue();
            if (key.len == 0 or value.len < K) {
                return error.InvalidDatabase;
            }

            return Node{
                .level = key[0],
                .key = if (key.len == 1) null else key[1..],
                .hash = value[0..K],
                .value = if (key[0] == 0) value[K..] else null,
            };
        }

        fn log(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.logger.print(format, args);
        }
    };
}
