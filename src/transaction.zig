const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const expectEqualSlices = std.testing.expectEqualSlices;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const Tree = @import("tree.zig").Tree;
const Header = @import("header.zig").Header;
const Logger = @import("logger.zig").Logger;
const BufferPool = @import("buffer_pool.zig").BufferPool;

const library = @import("library.zig");
const utils = @import("utils.zig");
const print = @import("print.zig");

const Result = enum { update, delete };

const OperationTag = enum { set, delete };
const Operation = union(OperationTag) {
    set: struct { key: []const u8, value: []const u8 },
    delete: []const u8,
};

pub fn Transaction(comptime K: u8, comptime Q: u32) type {
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

        pub fn open(allocator: std.mem.Allocator, tree: *const Tree(K, Q), options: Options) !*Self {
            const txn = try lmdb.Transaction.open(tree.env, .{ .read_only = options.read_only });
            errdefer txn.abort();

            const cursor = try lmdb.Cursor.open(txn);
            errdefer cursor.close();

            try Header(K, Q).validate(txn);

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

        pub fn get(self: *Self, key: []const u8) !?[]const u8 {
            if (try self.getNode(0, key)) |value| {
                return try getNodeValue(value);
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
                    utils.hashEntry(entry.key, entry.value, self.value_buffer.items[0..K]);
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
            const limit: comptime_int = (1 << 32) / @intCast(u33, Q);
            return std.mem.readIntBig(u32, value[0..4]) < limit;
        }

        fn getNodeHash(value: []const u8) !*const [K]u8 {
            if (value.len < K) {
                return error.InvalidDatabase;
            } else {
                return value[0..K];
            }
        }

        fn getNodeValue(value: []const u8) ![]const u8 {
            if (value.len < K) {
                return error.InvalidDatabase;
            } else {
                return value[K..];
            }
        }

        fn log(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.logger.print(format, args);
        }
    };
}

fn testEntryList(comptime K: u8, comptime Q: u32, t: library.Test, log: ?std.fs.File.Writer) !void {
    const allocator = std.heap.c_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const tree = try Tree(K, Q).open(allocator, path, .{});
    defer tree.close();

    {
        const txn = try Transaction(K, Q).open(allocator, tree, .{ .read_only = false, .log = log });
        errdefer txn.abort();
        for (t.leaves) |leaf| try txn.set(leaf[0], leaf[1]);
        try txn.commit();
    }

    try lmdb.expectEqualEntries(tree.env, t.entries);
}

fn l(comptime N: u8) [1]u8 {
    return [1]u8{N};
}

fn h(comptime value: *const [64]u8) [32]u8 {
    var buffer: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

test "Transaction.get" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const tree = try Tree(32, 4).open(allocator, path, .{});
    defer tree.close();

    const txn = try Transaction(32, 4).open(allocator, tree, .{ .read_only = false });
    defer txn.abort();

    try txn.set("a", "foo");
    try txn.set("b", "bar");
    try txn.set("c", "baz");

    try if (try txn.get("b")) |value| try expectEqualSlices(u8, value, "bar") else error.NotFound;
    try if (try txn.get("a")) |value| try expectEqualSlices(u8, value, "foo") else error.NotFound;
    try if (try txn.get("c")) |value| try expectEqualSlices(u8, value, "baz") else error.NotFound;
}

test "Transaction.set" {
    for (&library.tests) |t| {
        try testEntryList(32, 4, t, null);
    }
}

// test "Transaction.delete" {
//     const allocator = std.heap.c_allocator;

//     var tmp = std.testing.tmpDir(.{});
//     defer tmp.cleanup();

//     const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
//     defer allocator.free(path);

//     const tree = try Tree(32, 4).open(allocator, path, .{});
//     defer tree.close();

//     {
//         const txn = try Transaction(32, 4).open(allocator, tree, .{ .read_only = false });
//         errdefer txn.abort();

//         try txn.set("a", "foo");
//         try txn.set("b", "bar");
//         try txn.set("c", "baz");
//         try txn.set("d", "wow");
//         try txn.set("e", "aaa");

//         try txn.delete("b");

//         try txn.commit();
//     }

//     const entries = [_]Entry{
//         // Blake3() = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
//         .{ &l(0), &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
//         .{ &[_]u8{ 0, 'a' }, h("04e0bb39f30b1a3feb89f536c93be15055482df748674b00d26e5a75777702e9") ++ "foo" },
//         .{ &[_]u8{ 0, 'c' }, h("9624faa79d245cea9c345474fdb1a863b75921a8dd7aff3d84b22c65d1fc0847") ++ "baz" },
//         .{ &[_]u8{ 0, 'd' }, h("f77f056978b0003579dd044debc30cf5e287103387ddceeb7787ab3daca558cf") ++ "wow" },
//         .{ &[_]u8{ 0, 'e' }, h("30c0f9c6a167fc2a91285c85be7ea341569b3b39fcc5f77fd34534cade971d20") ++ "aaa" }, // X

//         .{ &l(1), &h("b547e541829b617963555c3ac160205444edbbce2799c5f5d678ba94bd770af8") },
//         .{ &[_]u8{ 1, 'e' }, &h("92caac92c967d76cb792411bb03a24585843f4e64b0b22d9a111d31dc8c249ac") },

//         .{ &l(2), &h("3bb085a04453e838efb7180ff1e4669f093a9eecd17e8131f3e1c2147de1b386") },

//         .{ &l(0xFF), &[_]u8{ 'o', 'k', 'r', 'a', 1, 4, 32 } },
//     };

//     try lmdb.expectEqualEntries(tree.env, &entries);
// }
