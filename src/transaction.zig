const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const Tree = @import("tree.zig").Tree;
const Header = @import("header.zig").Header;
const Logger = @import("logger.zig").Logger;
const BufferPool = @import("buffer_pool.zig").BufferPool;

const utils = @import("utils.zig");

const Result = enum { update, delete };

const OperationTag = enum { set, delete };
const Operation = union(OperationTag) {
    set: struct { key: []const u8, value: []const u8 },
    delete: []const u8,
};

pub fn Transaction(comptime Q: u8, comptime K: u8) type {
    return struct {
        allocator: std.mem.Allocator,
        txn: lmdb.Transaction,
        cursor: lmdb.Cursor,

        value_buffer: std.ArrayList(u8),
        key_buffer: std.ArrayList(u8),
        hash_buffer: [K]u8,
        pool: BufferPool,
        new_siblings: std.ArrayList([]const u8),
        logger: Logger,

        const Self = @This();

        pub const Options = struct { read_only: bool, log: ?std.fs.File.Writer = null };

        pub fn open(allocator: std.mem.Allocator, tree: *const Tree(Q, K), options: Options) !*Self {
            const txn = try lmdb.Transaction.open(tree.env, .{ .read_only = options.read_only });
            errdefer txn.abort();

            const cursor = try lmdb.Cursor.open(txn);
            errdefer cursor.close();

            try Header(Q, K).validate(txn);

            const self = try allocator.create(Self);
            self.allocator = allocator;
            self.txn = txn;
            self.cursor = cursor;
            self.pool = BufferPool.init(allocator);
            self.key_buffer = std.ArrayList(u8).init(allocator);
            self.value_buffer = std.ArrayList(u8).init(allocator);
            self.new_siblings = std.ArrayList([]const u8).init(allocator);
            self.logger = Logger.init(allocator, options.log);
            return self;
        }

        pub fn abort(self: *Self) void {
            defer self.deinit();
            self.txn.abort();
        }

        pub fn commit(self: *Self) !void {
            defer self.deinit();
            try self.txn.commit();
        }

        fn deinit(self: *Self) void {
            self.pool.deinit();
            self.key_buffer.deinit();
            self.value_buffer.deinit();
            self.new_siblings.deinit();
            self.logger.deinit();
            self.allocator.destroy(self);
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
            // go to root
            try self.cursor.goToKey(&Header(K, Q).HEADER_KEY);
            const height = try if (try self.cursor.goToPrevious()) |key| key[0] else error.InvalidDatabase;

            try self.log("height: {d}", .{height});

            var root_level = if (height == 0) 1 else height;

            self.logger.reset();
            try self.new_siblings.resize(0);
            try self.pool.allocate(root_level - 1);

            const nil = [_]u8{};
            const result = try switch (height) {
                0 => self.applyLeaf(&nil, operation),
                else => self.applyNode(root_level - 1, &nil, operation),
            };

            try switch (result) {
                Result.update => {},
                Result.delete => error.InsertError,
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
                    try self.value_buffer.resize(K + entry.value.len);
                    Blake3.hash(entry.value, self.value_buffer.items[0..K], .{});
                    std.mem.copy(u8, self.value_buffer.items[K..], entry.value);
                    try self.setNode(0, entry.key, self.value_buffer.items);

                    if (std.mem.lessThan(u8, first_child, entry.key)) {
                        if (isSplit(self.value_buffer.items[0..K])) {
                            try self.new_siblings.append(entry.key);
                        }
                    } else {
                        return error.WTF;
                    }

                    return Result.update;
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
                } else if (try self.getNode(level - 1, previous_child)) |previous_grand_child_value| {
                    const previous_grand_child_hash = try getNodeHash(previous_grand_child_value);
                    if (isSplit(previous_grand_child_hash)) {
                        return try self.pool.copy(id, previous_child);
                    }
                }

                try self.cursor.deleteCurrentKey();
            }

            return error.InsertError;
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
                const value = try self.cursor.getCurrentValue();
                const hash = try getNodeHash(value);
                if (key.len == 0) {
                    try self.log("- hashing {s} <- null", .{hex(hash)});
                } else {
                    try self.log("- hashing {s} <- {s}", .{ hex(hash), hex(key) });
                }

                digest.update(hash);
            }

            while (try self.goToNext(level - 1)) |next_key| {
                const value = try self.cursor.getCurrentValue();
                const hash = try getNodeHash(value);
                if (isSplit(hash)) break;
                try self.log("- hashing {s} <- {s}", .{ hex(hash), hex(next_key) });
                digest.update(hash);
            }

            var value: [K]u8 = undefined;
            digest.final(&value);
            try self.log("--------- {s}", .{hex(&value)});

            if (key.len == 0) {
                try self.log("setting {s} <- ({d}) null", .{ hex(&value), level });
            } else {
                try self.log("setting {s} <- ({d}) {s}", .{ hex(&value), level, hex(key) });
            }

            try self.setNode(level, key, &value);
            return isSplit(&value);
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

        fn setKey(self: *Self, level: u8, key: []const u8) !void {
            try self.key_buffer.resize(1 + key.len);
            self.key_buffer.items[0] = level;
            std.mem.copy(u8, self.key_buffer.items[1..], key);
        }

        fn getNode(self: *Self, level: u8, key: []const u8) !?[]const u8 {
            try self.setKey(level, key);
            return try self.txn.get(self.key_buffer.items);
        }

        fn setNode(self: *Self, level: u8, key: []const u8, value: []const u8) !void {
            try self.setKey(level, key);
            try self.txn.set(self.key_buffer.items, value);
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

        fn isSplit(value: *const [K]u8) bool {
            const limit: comptime_int = 256 / @intCast(u16, Q);
            return value[K - 1] < limit;
        }

        fn getNodeHash(value: []const u8) !*const [K]u8 {
            if (value.len < K) {
                return error.InvalidDatabase;
            } else {
                return value[0..K];
            }
        }

        fn log(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.logger.print(format, args);
        }
    };
}

const Entry = [2][]const u8;

fn testEntryList(comptime Q: u8, comptime K: u8, leaves: []const Entry, entries: []const Entry, log: ?std.fs.File.Writer) !void {
    const allocator = std.heap.c_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const tree = try Tree(Q, K).open(allocator, path, .{});
    defer tree.close();

    // const env = try lmdb.Environment.open(path, .{});
    // defer env.close();

    // try Header(Q, K).initialize(env);

    {
        const txn = try Transaction(Q, K).open(allocator, tree, .{ .read_only = false, .log = log });
        errdefer txn.abort();
        for (leaves) |leaf| try txn.set(leaf[0], leaf[1]);
        try txn.commit();
    }

    try lmdb.expectEqualEntries(tree.env, entries);
}

fn l(comptime N: u8) [1]u8 {
    return [1]u8{N};
}

fn h(comptime value: *const [64]u8) [32]u8 {
    var buffer: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

test "Transaction.set(a, b, c)" {
    // const log = std.io.getStdErr().writer();
    // try log.print("\n", .{});

    const leaves = [_]Entry{
        .{ "a", "foo" }, // Blake3("foo") = 04e0bb39f30b1a3feb89f536c93be15055482df748674b00d26e5a75777702e9
        .{ "b", "bar" }, // Blake3("bar") = f2e897eed7d206cd855d441598fa521abc75aa96953e97c030c9612c30c1293d
        .{ "c", "baz" }, // Blake3("baz") = 9624faa79d245cea9c345474fdb1a863b75921a8dd7aff3d84b22c65d1fc0847
    };

    const entries = [_]Entry{
        // Blake3() = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
        .{ &l(0), &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{ 0, 'a' }, h("04e0bb39f30b1a3feb89f536c93be15055482df748674b00d26e5a75777702e9") ++ "foo" },
        .{ &[_]u8{ 0, 'b' }, h("f2e897eed7d206cd855d441598fa521abc75aa96953e97c030c9612c30c1293d") ++ "bar" }, // X
        .{ &[_]u8{ 0, 'c' }, h("9624faa79d245cea9c345474fdb1a863b75921a8dd7aff3d84b22c65d1fc0847") ++ "baz" },

        .{ &l(1), &h("67d7843048360902858aaad05aad36160453583837929d0d864983abccd46c13") },
        .{ &[_]u8{ 1, 'b' }, &h("e902487cdf8c101eb5948eca70f3ba2bfa5ade4c68554b8d009c7e76de0b2a75") },

        .{ &l(2), &h("3bb418b5746a2a7604f8ca73bb9270cd848c046ff3a3dcfdd0c53f063a8fd437") },

        .{ &l(0xFF), &[_]u8{ 'o', 'k', 'r', 'a', 1, 4, 32 } },
    };

    try testEntryList(4, 32, &leaves, &entries, null);
}

test "Transaction.set(a, b, c, d)" {
    const leaves = [_]Entry{
        .{ "a", "foo" }, // Blake3("foo") = 04e0bb39f30b1a3feb89f536c93be15055482df748674b00d26e5a75777702e9
        .{ "b", "bar" }, // Blake3("bar") = f2e897eed7d206cd855d441598fa521abc75aa96953e97c030c9612c30c1293d
        .{ "c", "baz" }, // Blake3("baz") = 9624faa79d245cea9c345474fdb1a863b75921a8dd7aff3d84b22c65d1fc0847
        .{ "d", "wow" }, // Blake3("wow") = f77f056978b0003579dd044debc30cf5e287103387ddceeb7787ab3daca558cf
    };

    const entries = [_]Entry{
        // Blake3() = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
        .{ &l(0), &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{ 0, 'a' }, h("04e0bb39f30b1a3feb89f536c93be15055482df748674b00d26e5a75777702e9") ++ "foo" },
        .{ &[_]u8{ 0, 'b' }, h("f2e897eed7d206cd855d441598fa521abc75aa96953e97c030c9612c30c1293d") ++ "bar" }, // X
        .{ &[_]u8{ 0, 'c' }, h("9624faa79d245cea9c345474fdb1a863b75921a8dd7aff3d84b22c65d1fc0847") ++ "baz" },
        .{ &[_]u8{ 0, 'd' }, h("f77f056978b0003579dd044debc30cf5e287103387ddceeb7787ab3daca558cf") ++ "wow" },

        .{ &l(1), &h("67d7843048360902858aaad05aad36160453583837929d0d864983abccd46c13") },
        .{ &[_]u8{ 1, 'b' }, &h("288703d01f2825e778e838ab13491252df2a602600cc9a884bde8f8ed7fbf2ec") },

        .{ &l(2), &h("eb5cc9238879ee44989613de77b6e472b1c5e80bea89f83e6b4361f1e7d62e1e") },

        .{ &l(0xFF), &[_]u8{ 'o', 'k', 'r', 'a', 1, 4, 32 } },
    };

    try testEntryList(4, 32, &leaves, &entries, null);
}

test "Transaction.set(a, b, c, d, e)" {
    const leaves = [_]Entry{
        .{ "a", "foo" }, // Blake3("foo") = 04e0bb39f30b1a3feb89f536c93be15055482df748674b00d26e5a75777702e9
        .{ "b", "bar" }, // Blake3("bar") = f2e897eed7d206cd855d441598fa521abc75aa96953e97c030c9612c30c1293d
        .{ "c", "baz" }, // Blake3("baz") = 9624faa79d245cea9c345474fdb1a863b75921a8dd7aff3d84b22c65d1fc0847
        .{ "d", "wow" }, // Blake3("wow") = f77f056978b0003579dd044debc30cf5e287103387ddceeb7787ab3daca558cf
        .{ "e", "aaa" }, // Blake3("aaa") = 30c0f9c6a167fc2a91285c85be7ea341569b3b39fcc5f77fd34534cade971d20
    };

    const entries = [_]Entry{
        // Blake3() = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
        .{ &l(0), &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{ 0, 'a' }, h("04e0bb39f30b1a3feb89f536c93be15055482df748674b00d26e5a75777702e9") ++ "foo" },
        .{ &[_]u8{ 0, 'b' }, h("f2e897eed7d206cd855d441598fa521abc75aa96953e97c030c9612c30c1293d") ++ "bar" }, // X
        .{ &[_]u8{ 0, 'c' }, h("9624faa79d245cea9c345474fdb1a863b75921a8dd7aff3d84b22c65d1fc0847") ++ "baz" },
        .{ &[_]u8{ 0, 'd' }, h("f77f056978b0003579dd044debc30cf5e287103387ddceeb7787ab3daca558cf") ++ "wow" },
        .{ &[_]u8{ 0, 'e' }, h("30c0f9c6a167fc2a91285c85be7ea341569b3b39fcc5f77fd34534cade971d20") ++ "aaa" }, // X

        .{ &l(1), &h("67d7843048360902858aaad05aad36160453583837929d0d864983abccd46c13") },
        .{ &[_]u8{ 1, 'b' }, &h("288703d01f2825e778e838ab13491252df2a602600cc9a884bde8f8ed7fbf2ec") },
        .{ &[_]u8{ 1, 'e' }, &h("92caac92c967d76cb792411bb03a24585843f4e64b0b22d9a111d31dc8c249ac") },

        .{ &l(2), &h("14fec7a3a3adb21d33a25641094dc50f9da3a074b11f6b3bd59a7d067a5f5321") },

        .{ &l(0xFF), &[_]u8{ 'o', 'k', 'r', 'a', 1, 4, 32 } },
    };

    try testEntryList(4, 32, &leaves, &entries, null);
}

test "Transaction.delete(b)" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const tree = try Tree(4, 32).open(allocator, path, .{});
    defer tree.close();

    {
        const txn = try Transaction(4, 32).open(allocator, tree, .{ .read_only = false });
        errdefer txn.abort();

        try txn.set("a", "foo");
        try txn.set("b", "bar");
        try txn.set("c", "baz");
        try txn.set("d", "wow");
        try txn.set("e", "aaa");

        try txn.delete("b");

        try txn.commit();
    }

    const entries = [_]Entry{
        // Blake3() = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
        .{ &l(0), &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{ 0, 'a' }, h("04e0bb39f30b1a3feb89f536c93be15055482df748674b00d26e5a75777702e9") ++ "foo" },
        .{ &[_]u8{ 0, 'c' }, h("9624faa79d245cea9c345474fdb1a863b75921a8dd7aff3d84b22c65d1fc0847") ++ "baz" },
        .{ &[_]u8{ 0, 'd' }, h("f77f056978b0003579dd044debc30cf5e287103387ddceeb7787ab3daca558cf") ++ "wow" },
        .{ &[_]u8{ 0, 'e' }, h("30c0f9c6a167fc2a91285c85be7ea341569b3b39fcc5f77fd34534cade971d20") ++ "aaa" }, // X

        .{ &l(1), &h("b547e541829b617963555c3ac160205444edbbce2799c5f5d678ba94bd770af8") },
        .{ &[_]u8{ 1, 'e' }, &h("92caac92c967d76cb792411bb03a24585843f4e64b0b22d9a111d31dc8c249ac") },

        .{ &l(2), &h("3bb085a04453e838efb7180ff1e4669f093a9eecd17e8131f3e1c2147de1b386") },

        .{ &l(0xFF), &[_]u8{ 'o', 'k', 'r', 'a', 1, 4, 32 } },
    };

    try lmdb.expectEqualEntries(tree.env, &entries);
}

test "Transaction.set(...iota(10))" {
    var keys: [10][1]u8 = undefined;
    var leaves: [10]Entry = undefined;
    for (leaves) |*leaf, i| {
        keys[i] = .{@intCast(u8, i)};
        leaf[0] = &keys[i];
        leaf[1] = &keys[i];
    }

    const entries = [_]Entry{
        // Blake3() = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
        .{ &l(0), &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{ 0, 0 }, &h("2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213") ++ [_]u8{0} }, // X
        .{ &[_]u8{ 0, 1 }, &h("48fc721fbbc172e0925fa27af1671de225ba927134802998b10a1568a188652b") ++ [_]u8{1} }, // X
        .{ &[_]u8{ 0, 2 }, &h("ab13bedf42e84bae0f7c62c7dd6a8ada571e8829bed6ea558217f0361b5e25d0") ++ [_]u8{2} },
        .{ &[_]u8{ 0, 3 }, &h("e1e0e81d6ea39b0cf8b86ffd440921011f57400cbc3f76a8a171906a9b8d7505") ++ [_]u8{3} }, // X
        .{ &[_]u8{ 0, 4 }, &h("0c389a743e34fda435fbd575bb889dbc0d3e66b9f9d81e00be33b7188509e7eb") ++ [_]u8{4} },
        .{ &[_]u8{ 0, 5 }, &h("84cb40e74f0e856bb4bb91233e3cb74113533dca78a74f36f59edaa41895c946") ++ [_]u8{5} },
        .{ &[_]u8{ 0, 6 }, &h("1c310b6bdadd69991cd4e5dbef96c2638536c32b534e3ed64785846bfcebd206") ++ [_]u8{6} }, // X
        .{ &[_]u8{ 0, 7 }, &h("448bd8dd9624154a690f8e84dc52d6f633ba7cd545c4d3c9b4e0f6a2f6fa71f4") ++ [_]u8{7} },
        .{ &[_]u8{ 0, 8 }, &h("2ef3e0dda5293bda965d0adcedfc7d387244ac736a6014a720c1d63fa0ede02f") ++ [_]u8{8} }, // X
        .{ &[_]u8{ 0, 9 }, &h("7219aa1099ced7445c5bf949990ff7d9f6b71a94b8ec02b3eb61fb175a66ba25") ++ [_]u8{9} }, // X

        .{ &l(1), &h("82878ed8a480ee41775636820e05a934ca5c747223ca64306658ee5982e6c227") },
        .{ &[_]u8{ 1, 0 }, &h("2bf4d007e0cefcaf167e4641bb0f343b402775122dbff17b11514e9cbd21eefa") },
        .{ &[_]u8{ 1, 1 }, &h("2643fa74cd323c0d80963207ac617d364087e2075e1aa60ba1c9ef461cd28a7e") },
        .{ &[_]u8{ 1, 3 }, &h("26977730d18b3c9b1cd2686cd0a652ae96b0436df139e7d86720f1ee91938c34") }, // X
        .{ &[_]u8{ 1, 6 }, &h("1ae6a54db8771034d29819d581a0888aedb4413d487dfbec829afcde65f56739") }, // X
        .{ &[_]u8{ 1, 8 }, &h("658ef7986461d149a32fbdf388d0b2462fe3ffd9ee4dcacdee6c88acebc7683e") }, // X
        .{ &[_]u8{ 1, 9 }, &h("42fe831828cf7b7d36994c09daddd0836a7c0824a785da9d210e082b3ca3dfcf") },

        .{ &l(2), &h("68298f140c2d3134cc6903e10ddabde422fd82a053d6e5924c0bd3be744e3eea") },
        .{ &[_]u8{ 2, 3 }, &h("767a1e8ed80d0c112764038aa1497a6b13dc510cc34a20b0b53442bb8e43fb44") },
        .{ &[_]u8{ 2, 6 }, &h("43f3c35260be0d1548330ac64fdf6466daade876e5b116d0bd831964a3f2504c") },
        .{ &[_]u8{ 2, 8 }, &h("faadc84f2e67b7b327dc0a0a9cf985e9c2f977125375ba1ca4ed4c4e62c76f60") },

        .{ &l(3), &h("de0f72f05274264af6dd0103470a3bd4e2b4ef5588ef3a00e06682e969753399") },

        .{ &l(0xFF), &[_]u8{ 'o', 'k', 'r', 'a', 1, 4, 32 } },
    };

    try testEntryList(4, 32, &leaves, &entries, null);
}
