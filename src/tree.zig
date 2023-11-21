const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const Effects = @import("effects.zig");
const Logger = @import("logger.zig").Logger;
const BufferPool = @import("buffer_pool.zig").BufferPool;

const utils = @import("utils.zig");
const fmtKey = utils.fmtKey;

const nil = [0]u8{};

pub fn Tree(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);
    const Encoder = @import("encoder.zig").Encoder(K, Q);
    const Node = @import("node.zig").Node(K, Q);
    const NodeList = @import("node_list.zig").NodeList(K, Q);

    const Cursor = @import("cursor.zig").Cursor(K, Q);

    return struct {
        const Self = @This();

        pub const Options = struct {
            log: ?std.fs.File.Writer = null,
            trace: ?*NodeList = null,
            effects: ?*Effects = null,
        };

        txn: lmdb.Transaction,
        dbi: lmdb.Transaction.DBI,
        cursor: Cursor,
        logger: Logger,
        pool: BufferPool,
        encoder: Encoder,
        new_siblings: std.ArrayList(?[]const u8),
        effects: ?*Effects = null,
        trace: ?*NodeList = null,
        hash_buffer: [K]u8 = undefined,

        pub fn open(allocator: std.mem.Allocator, txn: lmdb.Transaction, dbi: lmdb.Transaction.DBI, options: Options) !Self {
            var tree: Self = undefined;
            try tree.init(allocator, txn, dbi, options);
            return tree;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, txn: lmdb.Transaction, dbi: lmdb.Transaction.DBI, options: Options) !void {
            self.txn = txn;
            self.dbi = dbi;
            self.cursor = try Cursor.open(allocator, txn, dbi, .{
                .effects = options.effects,
                .trace = options.trace,
            });

            self.logger = Logger.init(allocator, options.log);
            self.pool = BufferPool.init(allocator);
            self.encoder = Encoder.init(allocator);
            self.new_siblings = std.ArrayList(?[]const u8).init(allocator);
            self.effects = options.effects;
            self.trace = options.trace;

            try Header.initialize(txn, dbi);
        }

        pub fn close(self: *Self) void {
            self.cursor.close();
            self.logger.deinit();
            self.pool.deinit();
            self.encoder.deinit();
            self.new_siblings.deinit();
        }

        // Internal tree operations

        pub fn getRoot(self: *Self) !Node {
            return try self.cursor.goToRoot();
        }

        pub fn getNode(self: *Self, level: u8, key: ?[]const u8) !?Node {
            const entry_key = try self.encoder.encodeKey(level, key);
            if (try self.txn.get(self.dbi, entry_key)) |entry_value| {
                return try Node.parse(entry_key, entry_value);
            } else {
                return null;
            }
        }

        fn setNode(self: *Self, node: Node) !void {
            const entry = try self.encoder.encode(node);
            if (self.trace) |trace| try trace.append(node);
            if (self.effects) |effects| {
                if (try self.txn.get(self.dbi, entry.key)) |_| {
                    effects.update += 1;
                } else {
                    effects.create += 1;
                }
            }

            try self.txn.set(self.dbi, entry.key, entry.value);
        }

        fn deleteNode(self: *Self, level: u8, key: ?[]const u8) !void {
            const entry_key = try self.encoder.encodeKey(level, key);
            if (self.effects) |effects| effects.delete += 1;
            try self.txn.delete(self.dbi, entry_key);
        }

        // External tree operations

        const OperationType = enum { set, delete };
        const OperationTag = union(OperationType) {
            set: struct { key: []const u8, value: []const u8 },
            delete: struct { key: []const u8 },
        };

        const Result = enum { update, delete };

        pub fn get(self: *Self, key: []const u8) !?[]const u8 {
            const entry_key = try self.encoder.encodeKey(0, key);
            if (try self.txn.get(self.dbi, entry_key)) |entry_value| {
                const node = try Node.parse(entry_key, entry_value);
                if (node.value) |value| {
                    return value;
                } else {
                    return error.InvalidDatabase11;
                }
            } else {
                return null;
            }
        }

        pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
            try self.apply(.{ .set = .{ .key = key, .value = value } });
        }

        pub fn delete(self: *Self, key: []const u8) !void {
            try self.apply(.{ .delete = .{ .key = key } });
        }

        fn apply(self: *Self, tag: OperationTag) !void {
            if (self.trace) |trace| trace.reset();
            if (self.effects) |effects| effects.* = Effects{};

            const root = try self.getRoot();
            try self.log("root: {d} [{s}]", .{ root.level, hex(root.hash) });

            var root_level = if (root.level == 0) 1 else root.level;

            self.logger.reset();
            try self.new_siblings.resize(0);
            try self.pool.allocate(root_level - 1);

            const result = try switch (root.level) {
                0 => self.applyLeaf(tag, null),
                else => self.applyNode(tag, root_level - 1, null),
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

        fn applyLeaf(self: *Self, tag: OperationTag, first_child: ?[]const u8) !Result {
            try self.log("applyLeaf({s})", .{fmtKey(first_child)});

            switch (tag) {
                .set => |operation| {
                    utils.hashEntry(operation.key, operation.value, &self.hash_buffer);
                    const leaf = Node{
                        .level = 0,
                        .key = operation.key,
                        .hash = &self.hash_buffer,

                        // TODO: wtf?
                        // some weird bug causes .value to be null if entry.value.len == 0.
                        // setting it to another explicit empty slice seems to fix it.
                        .value = if (operation.value.len == 0) &nil else operation.value,
                    };

                    try self.setNode(leaf);

                    if (utils.lessThan(first_child, operation.key)) {
                        if (leaf.isBoundary()) {
                            try self.new_siblings.append(operation.key);
                        }

                        return Result.update;
                    } else if (utils.equal(first_child, operation.key)) {
                        if (first_child == null or leaf.isBoundary()) {
                            return Result.update;
                        } else {
                            return Result.delete;
                        }
                    } else {
                        return error.InvalidDatabase12;
                    }
                },
                .delete => |operation| {
                    try self.deleteNode(0, operation.key);
                    if (utils.equal(operation.key, first_child)) {
                        return Result.delete;
                    } else {
                        return Result.update;
                    }
                },
            }
        }

        fn applyNode(self: *Self, tag: OperationTag, level: u8, first_child: ?[]const u8) !Result {
            try self.log("applyNode({d}, {s})", .{ level, fmtKey(first_child) });

            try self.logger.indent();
            defer self.logger.deindent();

            if (level == 0) {
                return self.applyLeaf(tag, first_child);
            }

            const key = switch (tag) {
                .set => |operation| operation.key,
                .delete => |operation| operation.key,
            };

            const target = try self.findTargetKey(level, first_child, key);
            try self.log("target: {s}", .{fmtKey(target)});

            const is_left_edge = first_child == null;
            try self.log("is_left_edge: {any}", .{is_left_edge});

            const is_first_child = utils.equal(target, first_child);
            try self.log("is_first_child: {any}", .{is_first_child});

            const result = try self.applyNode(tag, level - 1, target);
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
                    return error.InvalidDatabase13;
                }
            }

            return target;
        }

        fn moveToPreviousChild(self: *Self, level: u8, target: ?[]const u8) !?[]const u8 {
            assert(level > 0);
            const id = level - 1;

            // delete the entry and move to the previous child

            _ = try self.cursor.goToNode(level, target);
            try self.cursor.deleteCurrentNode();

            while (try self.cursor.goToPrevious()) |previous_node| {
                if (previous_node.key) |key| {
                    const previous_key = try self.pool.copy(id, key);
                    if (try self.getNode(level - 1, previous_key)) |previous_child| {
                        if (previous_child.isBoundary()) {
                            return previous_key;
                        }
                    }

                    try self.cursor.deleteCurrentNode();
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

        inline fn log(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.logger.print(format, args);
        }
    };
}
