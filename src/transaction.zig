const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const expectEqualSlices = std.testing.expectEqualSlices;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");
const utils = @import("utils.zig");
const fmtKey = utils.fmtKey;

const Result = enum { update, delete };

const OperationTag = enum { set, delete };
const Operation = union(OperationTag) {
    set: struct { key: []const u8, value: []const u8 },
    delete: []const u8,
};

const nil = [0]u8{};

pub fn Transaction(comptime K: u8, comptime Q: u32) type {
    const Node = @import("node.zig").Node(K, Q);
    const Tree = @import("tree.zig").Tree(K, Q);
    const Cursor = @import("cursor.zig").Cursor(K, Q);
    const Header = @import("header.zig").Header(K, Q);
    const Logger = @import("logger.zig").Logger;
    const NodeList = @import("node_list.zig").NodeList(K, Q);
    const BufferPool = @import("buffer_pool.zig").BufferPool;

    return struct {
        const Self = @This();
        pub const Mode = enum { ReadOnly, ReadWrite };
        pub const Effects = struct { create: usize = 0, update: usize = 0, delete: usize = 0, height: u8 = 0 };
        pub const Options = struct {
            mode: Mode,
            dbi: ?[*:0]const u8 = null,
            log: ?std.fs.File.Writer = null,
            trace: ?*NodeList = null,
            effects: ?*Effects = null,
        };

        allocator: std.mem.Allocator,
        is_open: bool = false,
        txn: lmdb.Transaction,
        cursor: Cursor,

        value_buffer: std.ArrayList(u8),
        key_buffer: std.ArrayList(u8),
        hash_buffer: [K]u8,
        pool: BufferPool,
        new_siblings: std.ArrayList(?[]const u8),
        logger: Logger,
        trace: ?*NodeList,
        effects: ?*Effects,

        pub fn open(allocator: std.mem.Allocator, tree: *const Tree, options: Options) !Self {
            var transaction: Self = undefined;
            try transaction.init(allocator, tree, options);
            return transaction;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, tree: *const Tree, options: Options) !void {
            if (options.dbi) |dbi| {
                const txn = try lmdb.Transaction.open(tree.env, .{ .read_only = true });
                defer txn.abort();
                if (try txn.get(std.mem.span(dbi)) == null) {
                    return error.DatabaseNotFound;
                }
            }

            const read_only = switch (options.mode) {
                .ReadOnly => true,
                .ReadWrite => false,
            };

            {
                const txn = try lmdb.Transaction.open(tree.env, .{ .read_only = read_only, .dbi = options.dbi });
                errdefer txn.abort();

                try Header.validate(txn);

                try self.cursor.init(allocator, txn);

                self.allocator = allocator;
                self.is_open = true;
                self.txn = txn;
                self.pool = BufferPool.init(allocator);
                self.key_buffer = std.ArrayList(u8).init(allocator);
                self.value_buffer = std.ArrayList(u8).init(allocator);
                self.new_siblings = std.ArrayList(?[]const u8).init(allocator);
                self.logger = Logger.init(allocator, options.log);
                self.trace = options.trace;
                self.effects = options.effects;
            }
        }

        pub fn abort(self: *Self) void {
            if (self.is_open) {
                self.is_open = false;
                self.deinit();
                self.cursor.close();
                self.txn.abort();
            }
        }

        pub fn commit(self: *Self) !void {
            if (self.is_open) {
                self.is_open = false;
                self.deinit();
                self.cursor.close();
                try self.txn.commit();
            } else {
                return error.TransactionClosed;
            }
        }

        fn deinit(self: *Self) void {
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

        pub fn getRoot(self: *Self) !Node {
            return try self.cursor.goToRoot();
        }

        fn apply(self: *Self, operation: Operation) !void {
            if (self.trace) |trace| trace.reset();
            if (self.effects) |effects| effects.* = Effects{};

            const root = try self.getRoot();
            try self.log("height: {d}", .{root.level});

            var root_level = if (root.level == 0) 1 else root.level;

            self.logger.reset();
            try self.new_siblings.resize(0);
            try self.pool.allocate(root_level - 1);

            const result = try switch (root.level) {
                0 => self.applyLeaf(null, operation),
                else => self.applyNode(root_level - 1, null, operation),
            };

            try switch (result) {
                Result.update => {},
                Result.delete => error.InternalError,
            };

            _ = try self.hashNode(root_level, null);

            try self.log("new_children: {d}", .{self.new_siblings.items.len});
            for (self.new_siblings.items) |child| {
                try self.log("- {s}", .{fmtKey(child)});
            }

            while (self.new_siblings.items.len > 0) {
                try self.promote(root_level);

                root_level += 1;
                _ = try self.hashNode(root_level, null);
                try self.log("new_children: {d}", .{self.new_siblings.items.len});
                for (self.new_siblings.items) |child| {
                    try self.log("- {s}", .{fmtKey(child)});
                }
            }

            while (root_level > 0) : (root_level -= 1) {
                _ = try self.cursor.goToNode(root_level - 1, null);
                if (try self.cursor.goToNext()) |_| {
                    break;
                } else {
                    try self.log("trim root from {d} to {d}", .{ root_level, root_level - 1 });
                    try self.deleteNode(root_level, null);
                }
            }

            if (self.effects) |effects| effects.height = root_level + 1;
        }

        fn applyLeaf(self: *Self, first_child: ?[]const u8, operation: Operation) !Result {
            switch (operation) {
                .set => |entry| {
                    utils.hashEntry(entry.key, entry.value, &self.hash_buffer);
                    const leaf = Node{
                        .level = 0,
                        .key = entry.key,
                        .hash = &self.hash_buffer,

                        // TODO: wtf?
                        // some weird bug causes .value to be null if entry.value.len == 0.
                        // setting it to another explicit empty slice seems to fix it.
                        .value = if (entry.value.len == 0) &nil else entry.value,
                    };

                    try self.setNode(leaf);

                    if (utils.lessThan(first_child, entry.key)) {
                        if (leaf.isBoundary()) {
                            try self.new_siblings.append(entry.key);
                        }

                        return Result.update;
                    } else if (utils.equal(first_child, entry.key)) {
                        if (first_child == null or leaf.isBoundary()) {
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
                    if (utils.equal(key, first_child)) {
                        return Result.delete;
                    } else {
                        return Result.update;
                    }
                },
            }
        }

        fn applyNode(self: *Self, level: u8, first_child: ?[]const u8, operation: Operation) !Result {
            try self.log("insertNode({d}, {s})", .{ level, fmtKey(first_child) });

            try self.logger.indent();
            defer self.logger.deindent();

            if (level == 0) {
                return self.applyLeaf(first_child, operation);
            }

            const key = switch (operation) {
                Operation.set => |entry| entry.key,
                Operation.delete => |key| key,
            };

            const target = try self.findTargetKey(level, first_child, key);
            try self.log("target: {s}", .{fmtKey(target)});

            const is_left_edge = first_child == null;
            try self.log("is_left_edge: {any}", .{is_left_edge});

            const is_first_child = utils.equal(target, first_child);
            try self.log("is_first_child: {any}", .{is_first_child});

            const result = try self.applyNode(level - 1, target, operation);
            switch (result) {
                Result.delete => try self.log("result: delete", .{}),
                Result.update => try self.log("result: update", .{}),
            }

            try self.log("new siblings: {d}", .{self.new_siblings.items.len});
            for (self.new_siblings.items) |child| {
                try self.log("- {s}", .{fmtKey(child)});
            }

            switch (result) {
                Result.delete => {
                    assert(!is_left_edge or !is_first_child);

                    // delete the entry and move to the previous child
                    const previous_child_key = try self.moveToPreviousChild(level, target);
                    try self.log("previous_child_key: {s}", .{fmtKey(previous_child_key)});

                    try self.promote(level);

                    const is_previous_child_boundary = try self.hashNode(level, previous_child_key);
                    if (is_first_child or utils.lessThan(previous_child_key, first_child)) {
                        if (is_previous_child_boundary) {
                            try self.new_siblings.append(previous_child_key);
                        }

                        return Result.delete;
                    } else if (utils.equal(previous_child_key, first_child)) {
                        if (is_left_edge or is_previous_child_boundary) {
                            return Result.update;
                        } else {
                            return Result.delete;
                        }
                    } else {
                        if (is_previous_child_boundary) {
                            try self.new_siblings.append(previous_child_key);
                        }

                        return Result.update;
                    }
                },
                Result.update => {
                    const is_target_boundary = try self.hashNode(level, target);
                    try self.log("is_target_boundary: {any}", .{is_target_boundary});

                    try self.promote(level);

                    // is_first_child means either target's original value was a boundary, or is_left_edge is true.
                    if (is_first_child) {
                        if (is_target_boundary or is_left_edge) {
                            return Result.update;
                        } else {
                            return Result.delete;
                        }
                    } else {
                        if (is_target_boundary) {
                            try self.new_siblings.append(target);
                        }

                        return Result.update;
                    }
                },
            }
        }

        fn findTargetKey(self: *Self, level: u8, first_child: ?[]const u8, key: []const u8) !?[]const u8 {
            assert(level > 0);
            const id = level - 1;
            var target: ?[]const u8 = null;
            if (first_child) |bytes| {
                target = try self.pool.copy(id, bytes);
            }

            _ = try self.cursor.goToNode(level, first_child);
            while (try self.cursor.goToNext()) |next_child_node| {
                if (next_child_node.key) |next_child_key| {
                    if (utils.lessThan(key, next_child_key)) {
                        break;
                    } else {
                        target = try self.pool.copy(id, next_child_key);
                    }
                } else {
                    return error.InvalidDatabase;
                }
            }

            return target;
        }

        inline fn copyKey(self: *Self, id: usize, key: ?[]const u8) !?[]const u8 {
            if (key) |bytes| {
                return try self.pool.copy(id, bytes);
            } else {
                return null;
            }
        }

        fn moveToPreviousChild(self: *Self, level: u8, target: ?[]const u8) !?[]const u8 {
            assert(level > 0);
            const id = level - 1;

            // delete the entry and move to the previous child

            _ = try self.cursor.goToNode(level, target);
            try self.cursor.deleteCurrentNode();
            if (self.effects) |effects| effects.delete += 1;

            while (try self.cursor.goToPrevious()) |previous_node| {
                if (previous_node.key) |key| {
                    const previous_key = try self.pool.copy(id, key);
                    if (try self.getNode(level - 1, previous_key)) |previous_child| {
                        if (previous_child.isBoundary()) {
                            return previous_key;
                        }
                    }

                    try self.cursor.deleteCurrentNode();
                    if (self.effects) |effects| effects.delete += 1;
                } else {
                    return null;
                }
            }

            return error.InternalError;
        }

        /// Computes and sets the hash of the given node.
        /// Doesn't assume anything about the current cursor position.
        fn hashNode(self: *Self, level: u8, key: ?[]const u8) !bool {
            try self.log("hashNode({d}, {s})", .{ level, fmtKey(key) });

            var digest = Blake3.init(.{});

            const first = try self.cursor.goToNode(level - 1, key);
            try self.log("- hashing {s} <- {s}", .{ hex(first.hash), fmtKey(key) });
            digest.update(first.hash);

            while (try self.cursor.goToNext()) |next| {
                if (next.isBoundary()) {
                    break;
                } else {
                    try self.log("- hashing {s} <- {s}", .{ hex(next.hash), fmtKey(next.key) });
                    digest.update(next.hash);
                }
            }

            digest.final(&self.hash_buffer);
            try self.log("--------- {s}", .{hex(&self.hash_buffer)});
            try self.log("setting {s} <- ({d}) {s}", .{ hex(&self.hash_buffer), level, fmtKey(key) });
            const node = Node{ .level = level, .key = key, .hash = &self.hash_buffer, .value = null };

            try self.setNode(node);
            return node.isBoundary();
        }

        fn promote(self: *Self, level: u8) !void {
            var old_index: usize = 0;
            var new_index: usize = 0;
            const new_sibling_count = self.new_siblings.items.len;
            while (old_index < new_sibling_count) : (old_index += 1) {
                const key = self.new_siblings.items[old_index];
                const is_boundary = try self.hashNode(level, key);
                if (is_boundary) {
                    self.new_siblings.items[new_index] = key;
                    new_index += 1;
                }
            }

            try self.new_siblings.resize(new_index);
        }

        pub fn getNode(self: *Self, level: u8, key: ?[]const u8) !?Node {
            const k = try self.setKey(level, key);
            if (try self.txn.get(k)) |v| {
                return try Node.parse(k, v);
            } else {
                return null;
            }
        }

        fn setNode(self: *Self, node: Node) !void {
            const k = try self.setKey(node.level, node.key);
            const v = try self.setValue(node.hash, node.value);

            if (self.trace) |trace| try trace.append(node);
            if (self.effects) |effects| {
                if (try self.txn.get(k)) |_| {
                    effects.update += 1;
                } else {
                    effects.create += 1;
                }
            }

            try self.txn.set(k, v);
        }

        fn deleteNode(self: *Self, level: u8, key: ?[]const u8) !void {
            const k = try self.setKey(level, key);

            if (self.effects) |effects| effects.delete += 1;

            try self.txn.delete(k);
        }

        fn setKey(self: *Self, level: u8, key: ?[]const u8) ![]const u8 {
            if (key) |bytes| {
                try self.key_buffer.resize(1 + bytes.len);
                self.key_buffer.items[0] = level;
                std.mem.copy(u8, self.key_buffer.items[1..], bytes);
            } else {
                try self.key_buffer.resize(1);
                self.key_buffer.items[0] = level;
            }

            return self.key_buffer.items;
        }

        fn setValue(self: *Self, hash: *const [K]u8, value: ?[]const u8) ![]const u8 {
            if (value) |bytes| {
                try self.value_buffer.resize(K + bytes.len);
                std.mem.copy(u8, self.value_buffer.items[0..K], hash);
                std.mem.copy(u8, self.value_buffer.items[K..], bytes);
            } else {
                try self.value_buffer.resize(K);
                std.mem.copy(u8, self.value_buffer.items, hash);
            }

            return self.value_buffer.items;
        }

        inline fn log(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.logger.print(format, args);
        }
    };
}
