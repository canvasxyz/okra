const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const expectEqualSlices = std.testing.expectEqualSlices;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");
const utils = @import("utils.zig");
const fmtKey = utils.fmtKey;

const Result = enum { update, delete };

const nil = [0]u8{};

pub fn Transaction(comptime K: u8, comptime Q: u32) type {
    const Node = @import("node.zig").Node(K, Q);
    const Tree = @import("tree.zig").Tree(K, Q);
    const Cursor = @import("cursor.zig").Cursor(K, Q);
    const Header = @import("header.zig").Header(K, Q);
    const Logger = @import("logger.zig").Logger;
    const NodeList = @import("node_list.zig").NodeList(K, Q);
    const BufferPool = @import("buffer_pool.zig").BufferPool;
    const NodeEncoder = @import("node_encoder.zig").NodeEncoder(K, Q);

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

        const OperationType = enum { set, delete };
        const OperationTag = union(OperationType) {
            set: struct { key: []const u8, value: []const u8 },
            delete: []const u8,
        };

        const Operation = struct {
            pub fn Set(key: []const u8, value: []const u8) OperationTag {
                return .{ .set = .{ .key = key, .value = value } };
            }

            pub fn Delete(key: []const u8) OperationTag {
                return .{ .delete = key };
            }

            tag: OperationTag,
            ctx: *Self,

            txn: lmdb.Transaction,
            cursor: Cursor,
            logger: Logger,

            trace: ?*NodeList = null,
            effects: ?*Effects = null,

            encoder: *NodeEncoder,
            pool: *BufferPool,
            new_siblings: *std.ArrayList(?[]const u8),
            hash_buffer: [K]u8 = undefined,

            pub fn init(allocator: std.mem.Allocator, ctx: *Self, tag: OperationTag) !Operation {
                const txn = try lmdb.Transaction.open(ctx.env, .{
                    .read_only = false,
                    .parent = ctx.txn,
                    .dbi = ctx.dbi,
                });

                const cursor = try Cursor.open(allocator, txn);
                return Operation{
                    .tag = tag,
                    .ctx = ctx,
                    .txn = txn,
                    .cursor = cursor,
                    .trace = ctx.trace,
                    .effects = ctx.effects,
                    .logger = Logger.init(allocator, ctx.log),

                    .encoder = &ctx.encoder,
                    .pool = &ctx.pool,
                    .new_siblings = &ctx.new_siblings,

                    // .encoder = NodeEncoder.init(allocator),
                    // .pool = BufferPool.init(allocator),
                    // .new_siblings = std.ArrayList(?[]const u8).init(allocator),
                };
            }

            pub fn abort(self: *Operation) void {
                self.deinit();
                self.cursor.close();
                self.txn.abort();
            }

            pub fn commit(self: *Operation) !void {
                self.deinit();
                self.cursor.close();
                try self.txn.commit();
            }

            pub fn deinit(self: *Operation) void {
                self.logger.deinit();
                // self.new_siblings.deinit();
                // self.encoder.deinit();
                // self.pool.deinit();
            }

            pub fn apply(self: *Operation) !void {
                if (self.trace) |trace| trace.reset();
                if (self.effects) |effects| effects.* = Effects{};

                const root = try self.cursor.goToRoot();
                try self.log("height: {d}", .{root.level});

                var root_level = if (root.level == 0) 1 else root.level;

                self.logger.reset();
                try self.new_siblings.resize(0);
                try self.pool.allocate(root_level - 1);

                const result = try switch (root.level) {
                    0 => self.applyLeaf(null),
                    else => self.applyNode(root_level - 1, null),
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

            fn applyLeaf(self: *Operation, first_child: ?[]const u8) !Result {
                switch (self.tag) {
                    .set => |tag| {
                        utils.hashEntry(tag.key, tag.value, &self.hash_buffer);
                        const leaf = Node{
                            .level = 0,
                            .key = tag.key,
                            .hash = &self.hash_buffer,

                            // TODO: wtf?
                            // some weird bug causes .value to be null if entry.value.len == 0.
                            // setting it to another explicit empty slice seems to fix it.
                            .value = if (tag.value.len == 0) &nil else tag.value,
                        };

                        try self.setNode(leaf);

                        if (utils.lessThan(first_child, tag.key)) {
                            if (leaf.isBoundary()) {
                                try self.new_siblings.append(tag.key);
                            }

                            return Result.update;
                        } else if (utils.equal(first_child, tag.key)) {
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

            fn applyNode(self: *Operation, level: u8, first_child: ?[]const u8) !Result {
                try self.log("insertNode({d}, {s})", .{ level, fmtKey(first_child) });

                try self.logger.indent();
                defer self.logger.deindent();

                if (level == 0) {
                    return self.applyLeaf(first_child);
                }

                const key = switch (self.tag) {
                    .set => |entry| entry.key,
                    .delete => |key| key,
                };

                const target = try self.findTargetKey(level, first_child, key);
                try self.log("target: {s}", .{fmtKey(target)});

                const is_left_edge = first_child == null;
                try self.log("is_left_edge: {any}", .{is_left_edge});

                const is_first_child = utils.equal(target, first_child);
                try self.log("is_first_child: {any}", .{is_first_child});

                const result = try self.applyNode(level - 1, target);
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

            fn findTargetKey(self: *Operation, level: u8, first_child: ?[]const u8, key: []const u8) !?[]const u8 {
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

            fn moveToPreviousChild(self: *Operation, level: u8, target: ?[]const u8) !?[]const u8 {
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
            fn hashNode(self: *Operation, level: u8, key: ?[]const u8) !bool {
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

            fn promote(self: *Operation, level: u8) !void {
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

            fn getNode(self: *Operation, level: u8, key: ?[]const u8) !?Node {
                const entry_key = try self.encoder.encodeKey(level, key);
                if (try self.txn.get(entry_key)) |entry_value| {
                    return try Node.parse(entry_key, entry_value);
                } else {
                    return null;
                }
            }

            fn setNode(self: *Operation, node: Node) !void {
                const entry = try self.encoder.encode(node);

                if (self.trace) |trace| try trace.append(node);
                if (self.effects) |effects| {
                    if (try self.txn.get(entry.key)) |_| {
                        effects.update += 1;
                    } else {
                        effects.create += 1;
                    }
                }

                try self.txn.set(entry.key, entry.value);
            }

            fn deleteNode(self: *Operation, level: u8, key: ?[]const u8) !void {
                const entry_key = try self.encoder.encodeKey(level, key);

                if (self.effects) |effects| effects.delete += 1;

                try self.txn.delete(entry_key);
            }

            inline fn log(self: *Operation, comptime format: []const u8, args: anytype) !void {
                try self.logger.print(format, args);
            }
        };

        allocator: std.mem.Allocator,
        is_open: bool = false,

        env: lmdb.Environment,
        txn: lmdb.Transaction,
        cursor: Cursor,

        dbi: ?[*:0]const u8,

        log: ?std.fs.File.Writer = null,
        trace: ?*NodeList,
        effects: ?*Effects,

        encoder: NodeEncoder,
        pool: BufferPool,
        new_siblings: std.ArrayList(?[]const u8),
        hash_buffer: [K]u8 = undefined,

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

            const txn = try lmdb.Transaction.open(tree.env, .{ .read_only = read_only, .dbi = options.dbi });
            errdefer txn.abort();

            try Header.validate(txn);

            self.allocator = allocator;
            self.is_open = true;

            self.env = tree.env;
            self.txn = txn;
            self.cursor = try Cursor.open(allocator, txn);

            if (options.dbi) |ptr| {
                const len = std.mem.indexOfSentinel(u8, 0, ptr);
                const dbi = try allocator.allocSentinel(u8, len, 0);
                std.mem.copy(u8, dbi, std.mem.span(ptr));
                self.dbi = dbi.ptr;
            } else {
                self.dbi = null;
            }

            self.log = options.log;
            self.trace = options.trace;
            self.effects = options.effects;

            self.encoder = NodeEncoder.init(allocator);
            self.pool = BufferPool.init(allocator);
            self.new_siblings = std.ArrayList(?[]const u8).init(allocator);
        }

        pub fn abort(self: *Self) void {
            if (self.is_open) {
                self.is_open = false;
                self.cursor.close();
                self.txn.abort();
            }
        }

        pub fn commit(self: *Self) !void {
            if (self.is_open) {
                self.is_open = false;
                self.cursor.close();
                try self.txn.commit();
            } else {
                return error.TransactionClosed;
            }
        }

        fn deinit(self: *Self) void {
            self.new_siblings.deinit();
            self.pool.deinit();
            self.encoder.deinit();
            if (self.dbi) |ptr| {
                self.allocator.free(ptr);
            }
        }

        pub fn get(self: *Self, key: []const u8) !?[]const u8 {
            const entry_key = try self.cursor.encoder.encodeKey(0, key);
            if (try self.txn.get(entry_key)) |entry_value| {
                const node = try Node.parse(entry_key, entry_value);
                if (node.value) |value| {
                    return value;
                } else {
                    return error.InvalidDatabase;
                }
            } else {
                return null;
            }
        }

        pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
            if (key.len == 0) {
                return error.InvalidKey;
            }

            var operation = try Operation.init(self.allocator, self, Operation.Set(key, value));

            errdefer operation.abort();
            try operation.apply();
            try operation.commit();
        }

        pub fn delete(self: *Self, key: []const u8) !void {
            if (key.len == 0) {
                return error.InvalidKey;
            }

            var operation = try Operation.init(self.allocator, self, Operation.Delete(key));

            errdefer operation.abort();
            try operation.apply();
            try operation.commit();
        }

        pub fn getRoot(self: *Self) !Node {
            return try self.cursor.goToRoot();
        }

        pub fn getNode(self: *Self, level: u8, key: ?[]const u8) !?Node {
            const entry_key = try self.cursor.encoder.encodeKey(level, key);
            if (try self.txn.get(entry_key)) |entry_value| {
                return try Node.parse(entry_key, entry_value);
            } else {
                return null;
            }
        }

        pub fn getUserdata(self: *Self) !?[]const u8 {
            return try self.txn.get(&Header.USERDATA_KEY);
        }

        pub fn setUserdata(self: *Self, userdata: ?[]const u8) !void {
            if (userdata) |value| {
                try self.txn.set(&Header.USERDATA_KEY, value);
            } else {
                try self.txn.delete(&Header.USERDATA_KEY);
            }
        }
    };
}
