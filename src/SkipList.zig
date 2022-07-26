const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");

const Logger = @import("logger.zig").Logger;
const utils = @import("utils.zig");
const constants = @import("constants.zig");
const printTree = @import("print.zig").printTree;

pub const SkipList = struct {
    pub const Options = struct {
        degree: u8 = 32,
        variant: utils.Variant = utils.Variant.MapIndex,
        log: ?std.fs.File.Writer = null,
    };

    const Result = enum { update, delete };
    const OperationTag = enum { set, delete };
    const Operation = union(OperationTag) {
        set: struct { key: []const u8, value: []const u8 },
        delete: []const u8,
    };

    allocator: std.mem.Allocator,
    variant: utils.Variant,
    limit: u8,

    key: std.ArrayList(u8),
    target_keys: std.ArrayList(std.ArrayList(u8)),
    new_siblings: std.ArrayList([]const u8),
    logger: Logger,

    pub fn open(allocator: std.mem.Allocator, env: lmdb.Environment, options: Options) !SkipList {
        var skip_list: SkipList = undefined;
        try skip_list.init(allocator, env, options);
        return skip_list;
    }

    pub fn init(self: *SkipList, allocator: std.mem.Allocator, env: lmdb.Environment, options: Options) !void {
        self.allocator = allocator;
        self.variant = options.variant;
        self.limit = try utils.getLimit(options.degree);
        self.key = std.ArrayList(u8).init(allocator);
        self.target_keys = std.ArrayList(std.ArrayList(u8)).init(allocator);
        self.new_siblings = std.ArrayList([]const u8).init(allocator);
        self.logger = Logger.init(allocator, options.log);

        errdefer self.deinit();

        // Initialize the metadata and root entries if necessary
        const txn = try lmdb.Transaction.open(env, .{ .read_only = false });
        if (try utils.getMetadata(txn)) |metadata| {
            defer txn.abort();
            if (metadata.degree != options.degree) {
                return error.InvalidDegree;
            } else if (metadata.variant != options.variant) {
                return error.InvalidVariant;
            }
        } else {
            errdefer txn.abort();
            var value: [32]u8 = undefined;
            Sha256.hash(&[0]u8{}, &value, .{});
            try txn.set(&[_]u8{0x00}, &value);
            try utils.setMetadata(txn, .{ .degree = options.degree, .variant = options.variant, .height = 0 });
            try txn.commit();
        }
    }

    pub fn deinit(self: *SkipList) void {
        self.key.deinit();
        for (self.target_keys.items) |key| key.deinit();
        self.target_keys.deinit();
        self.new_siblings.deinit();
        self.logger.deinit();
    }

    pub fn get(self: *SkipList, txn: lmdb.Transaction, key: []const u8) !?[]const u8 {
        if (key.len == 0) {
            return error.InvalidKey;
        } else {
            return try self.getNode(txn, 0, key);
        }
    }

    pub fn set(self: *SkipList, txn: lmdb.Transaction, cursor: lmdb.Cursor, key: []const u8, value: []const u8) !void {
        try self.log("set({s}, {s})", .{ hex(key), hex(value) });
        if (key.len == 0) {
            return error.InvalidKey;
        } else {
            try self.apply(txn, cursor, Operation{ .set = .{ .key = key, .value = value } });
        }
    }

    pub fn delete(self: *SkipList, txn: lmdb.Transaction, cursor: lmdb.Cursor, key: []const u8) !void {
        try self.log("delete({s})", .{hex(key)});
        if (key.len == 0) {
            return error.InvalidKey;
        } else {
            try self.apply(txn, cursor, Operation{ .delete = key });
        }
    }

    fn apply(self: *SkipList, txn: lmdb.Transaction, cursor: lmdb.Cursor, operation: Operation) !void {
        var metadata = try utils.getMetadata(txn) orelse return error.InvalidDatabase;
        try self.log("height: {d}", .{metadata.height});

        self.logger.reset();
        self.new_siblings.shrinkAndFree(0);

        const target_keys_len = self.target_keys.items.len;
        if (target_keys_len < metadata.height) {
            try self.target_keys.resize(metadata.height);
            for (self.target_keys.items[target_keys_len..]) |*key| {
                key.* = std.ArrayList(u8).init(self.allocator);
            }
        }

        var root_level = if (metadata.height == 0) 1 else metadata.height;

        const nil = [_]u8{};
        const result = try switch (metadata.height) {
            0 => self.applyLeaf(txn, cursor, &nil, operation),
            else => self.applyNode(txn, cursor, root_level - 1, &nil, operation),
        };

        try switch (result) {
            Result.update => {},
            Result.delete => error.InsertError,
        };

        _ = try self.hashNode(txn, cursor, root_level, &nil);

        try self.log("new_children: {d}", .{self.new_siblings.items.len});
        for (self.new_siblings.items) |child| try self.log("- {s}", .{hex(child)});

        while (self.new_siblings.items.len > 0) {
            try self.promote(txn, cursor, root_level);

            root_level += 1;
            _ = try self.hashNode(txn, cursor, root_level, &nil);
            try self.log("new_children: {d}", .{self.new_siblings.items.len});
            for (self.new_siblings.items) |child| try self.log("- {s}", .{hex(child)});
        }

        try self.goToNode(cursor, root_level, &nil);
        while (root_level > 0) : (root_level -= 1) {
            const last_key = try self.goToLast(cursor, root_level - 1);
            if (last_key.len > 0) {
                break;
            } else {
                try self.log("trim root from {d} to {d}", .{ root_level, root_level - 1 });
                try self.deleteNode(txn, root_level, &nil);
            }
        }

        try self.log("writing metadata entry with height {d}", .{root_level});
        metadata.height = root_level;
        try utils.setMetadata(txn, metadata);
    }

    fn applyNode(self: *SkipList, txn: lmdb.Transaction, cursor: lmdb.Cursor, level: u8, first_child: []const u8, operation: Operation) !Result {
        if (first_child.len == 0) {
            try self.log("insertNode({d}, null)", .{level});
        } else {
            try self.log("insertNode({d}, {s})", .{ level, hex(first_child) });
        }

        try self.logger.indent();
        defer self.logger.deindent();

        if (level == 0) {
            return self.applyLeaf(txn, cursor, first_child, operation);
        }

        const target = try switch (operation) {
            Operation.set => |entry| self.findTargetKey(txn, cursor, level, first_child, entry.key),
            Operation.delete => |key| self.findTargetKey(txn, cursor, level, first_child, key),
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

        const result = try self.applyNode(txn, cursor, level - 1, target, operation);
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
                const previous_child = try self.moveToPreviousChild(txn, cursor, level);
                if (previous_child.len == 0) {
                    try self.log("previous_child: null", .{});
                } else {
                    try self.log("previous_child: {s}", .{hex(previous_child)});
                }

                try self.promote(txn, cursor, level);

                const is_previous_child_split = try self.hashNode(txn, cursor, level, previous_child);
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
                const is_target_split = try self.hashNode(txn, cursor, level, target);
                try self.log("is_target_split: {any}", .{is_target_split});

                try self.promote(txn, cursor, level);

                // is_first_child means either target's original value was a split,
                // or is_left_edge is true.
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

    fn applyLeaf(self: *SkipList, txn: lmdb.Transaction, _: lmdb.Cursor, first_child: []const u8, operation: Operation) !Result {
        switch (operation) {
            .set => |entry| {
                if (std.mem.lessThan(u8, first_child, entry.key)) {
                    const hash = try utils.getHash(self.variant, entry.key, entry.value);
                    if (self.isSplit(hash)) {
                        try self.new_siblings.append(entry.key);
                    }
                }

                try self.setNode(txn, 0, entry.key, entry.value);
                return Result.update;
            },
            .delete => |key| {
                try self.deleteNode(txn, 0, key);
                if (std.mem.eql(u8, key, first_child)) {
                    return Result.delete;
                } else {
                    return Result.update;
                }
            },
        }
    }

    fn findTargetKey(self: *SkipList, _: lmdb.Transaction, cursor: lmdb.Cursor, level: u8, first_child: []const u8, key: []const u8) ![]const u8 {
        assert(level > 0);
        const target = &self.target_keys.items[level - 1];
        try utils.copy(target, first_child);

        try self.goToNode(cursor, level, first_child);
        while (try self.goToNext(cursor, level)) |next_child| {
            if (std.mem.lessThan(u8, key, next_child)) {
                return target.items;
            } else {
                try utils.copy(target, next_child);
            }
        }

        return target.items;
    }

    fn moveToPreviousChild(self: *SkipList, txn: lmdb.Transaction, cursor: lmdb.Cursor, level: u8) ![]const u8 {
        const target = &self.target_keys.items[level - 1];

        // delete the entry and move to the previous child
        try self.goToNode(cursor, level, target.items);

        try cursor.deleteCurrentKey();
        while (try self.goToPrevious(cursor, level)) |previous_child| {
            if (previous_child.len == 0) {
                target.shrinkAndFree(0);
                return target.items;
            } else if (try self.getNode(txn, level - 1, previous_child)) |previous_grand_child_value| {
                const previous_grand_child_hash = try utils.getHash(
                    self.variant,
                    previous_child,
                    previous_grand_child_value,
                );

                if (self.isSplit(previous_grand_child_hash)) {
                    try utils.copy(target, previous_child);
                    return target.items;
                }
            }

            try cursor.deleteCurrentKey();
        }

        return error.InsertError;
    }

    fn hashNode(self: *SkipList, txn: lmdb.Transaction, cursor: lmdb.Cursor, level: u8, key: []const u8) !bool {
        if (key.len == 0) {
            try self.log("hashNode({d}, null)", .{level});
        } else {
            try self.log("hashNode({d}, {s})", .{ level, hex(key) });
        }

        try self.goToNode(cursor, level - 1, key);
        var digest = Sha256.init(.{});

        {
            const value = try cursor.getCurrentValue();

            if (key.len == 0) {
                try self.log("- hashing {s} <- null", .{hex(value)});
            } else {
                try self.log("- hashing {s} <- {s}", .{ hex(value), hex(key) });
            }

            digest.update(value);
        }

        while (try self.goToNext(cursor, level - 1)) |next_key| {
            const next_value = try cursor.getCurrentValue();
            const next_hash = try utils.getHash(self.variant, next_key, next_value);
            if (self.isSplit(next_hash)) break;
            try self.log("- hashing {s} <- {s}", .{ hex(next_hash), hex(next_key) });
            digest.update(next_hash);
        }

        var value: [32]u8 = undefined;
        digest.final(&value);
        try self.log("--------- {s}", .{hex(&value)});

        if (key.len == 0) {
            try self.log("setting {s} <- ({d}) null", .{ hex(&value), level });
        } else {
            try self.log("setting {s} <- ({d}) {s}", .{ hex(&value), level, hex(key) });
        }

        try self.setNode(txn, level, key, &value);
        return self.isSplit(&value);
    }

    fn promote(self: *SkipList, txn: lmdb.Transaction, cursor: lmdb.Cursor, level: u8) !void {
        var old_index: usize = 0;
        var new_index: usize = 0;
        const new_sibling_count = self.new_siblings.items.len;
        while (old_index < new_sibling_count) : (old_index += 1) {
            const key = self.new_siblings.items[old_index];
            const is_split = try self.hashNode(txn, cursor, level, key);
            if (is_split) {
                self.new_siblings.items[new_index] = key;
                new_index += 1;
            }
        }

        self.new_siblings.shrinkAndFree(new_index);
    }

    fn setKey(self: *SkipList, level: u8, key: []const u8) !void {
        try self.key.resize(1 + key.len);
        self.key.items[0] = level;
        std.mem.copy(u8, self.key.items[1..], key);
    }

    fn getNode(self: *SkipList, txn: lmdb.Transaction, level: u8, key: []const u8) !?[]const u8 {
        try self.setKey(level, key);
        return try txn.get(self.key.items);
    }

    fn setNode(self: *SkipList, txn: lmdb.Transaction, level: u8, key: []const u8, value: []const u8) !void {
        try self.setKey(level, key);
        try txn.set(self.key.items, value);
    }

    fn deleteNode(self: *SkipList, txn: lmdb.Transaction, level: u8, key: []const u8) !void {
        try self.setKey(level, key);
        try txn.delete(self.key.items);
    }

    fn goToNode(self: *SkipList, cursor: lmdb.Cursor, level: u8, key: []const u8) !void {
        try self.setKey(level, key);
        try cursor.goToKey(self.key.items);
    }

    fn goToNext(_: *SkipList, cursor: lmdb.Cursor, level: u8) !?[]const u8 {
        if (try cursor.goToNext()) |key| {
            if (key[0] == level) {
                return key[1..];
            }
        }

        return null;
    }

    fn goToPrevious(_: *SkipList, cursor: lmdb.Cursor, level: u8) !?[]const u8 {
        if (try cursor.goToPrevious()) |key| {
            if (key[0] == level) {
                return key[1..];
            }
        }

        return null;
    }

    fn goToLast(self: *SkipList, cursor: lmdb.Cursor, level: u8) ![]const u8 {
        try self.goToNode(cursor, level + 1, &[_]u8{});

        if (try cursor.goToPrevious()) |previous_key| {
            if (previous_key[0] == level) {
                return previous_key[1..];
            }
        }

        return error.KeyNotFound;
    }

    fn isSplit(self: *const SkipList, value: *const [32]u8) bool {
        return value[31] < self.limit;
    }

    fn log(self: *SkipList, comptime format: []const u8, args: anytype) !void {
        try self.logger.print(format, args);
    }
};

const Entry = [2][]const u8;

test "SkipList()" {
    const allocator = std.heap.c_allocator;

    // const log = std.io.getStdErr().writer();
    // try log.print("\n", .{});

    var tmp = std.testing.tmpDir(.{});
    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    var skip_list = try SkipList.open(allocator, env, .{});
    defer skip_list.deinit();

    try lmdb.expectEqualEntries(env, &[_]Entry{
        .{ &[_]u8{
            0x00,
        }, &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },

        .{ &constants.METADATA_KEY, &[_]u8{ constants.DATABASE_VERSION, 0x20, 0x03, 0x00 } },
    });
}

test "SkipList(a, b, c)" {
    const allocator = std.heap.c_allocator;
    // const log = std.io.getStdErr().writer();
    // try log.print("\n", .{});

    var tmp = std.testing.tmpDir(.{});
    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    var skip_list = try SkipList.open(allocator, env, .{ .degree = 4 });
    defer skip_list.deinit();

    {
        var txn = try lmdb.Transaction.open(env, .{ .read_only = false });
        errdefer txn.abort();

        var cursor = try lmdb.Cursor.open(txn);
        try skip_list.set(txn, cursor, "a", &utils.hash("foo"));
        try skip_list.set(txn, cursor, "b", &utils.hash("bar"));
        try skip_list.set(txn, cursor, "c", &utils.hash("baz"));
        try txn.commit();
    }

    try lmdb.expectEqualEntries(env, &[_]Entry{
        .{ &[_]u8{
            0x00,
        }, &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
        .{ &[_]u8{ 0x00, 'a' }, &utils.parseHash("2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae") },
        .{ &[_]u8{ 0x00, 'b' }, &utils.parseHash("fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9") },
        .{ &[_]u8{ 0x00, 'c' }, &utils.parseHash("baa5a0964d3320fbc0c6a922140453c8513ea24ab8fd0577034804a967248096") },

        .{ &[_]u8{
            0x01,
        }, &utils.parseHash("1ca9140a5b30b5576694b7d45ce1af298d858a58dfa2376302f540ee75a89348") },

        .{ &constants.METADATA_KEY, &[_]u8{ constants.DATABASE_VERSION, 0x04, 0x03, 0x01 } },
    });
}

test "SkipList(10)" {
    const allocator = std.heap.c_allocator;
    // const log = std.io.getStdErr().writer();
    // try log.print("\n", .{});

    var tmp = std.testing.tmpDir(.{});
    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    var skip_list = try SkipList.open(allocator, env, .{ .degree = 4 });
    defer skip_list.deinit();

    // try log.print("----------------------------------------------------------------\n", .{});

    {
        var txn = try lmdb.Transaction.open(env, .{ .read_only = false });
        errdefer txn.abort();

        var cursor = try lmdb.Cursor.open(txn);

        var i: u8 = 0;
        while (i < 10) : (i += 1) {
            const key = [_]u8{i};
            try skip_list.set(txn, cursor, &key, &utils.hash(&key));
        }

        try txn.commit();
    }

    var keys: [10][1]u8 = undefined;
    var values: [10][32]u8 = undefined;
    var leaves: [10]Entry = undefined;
    for (leaves) |*leaf, i| {
        keys[i] = .{@intCast(u8, i)};
        leaf[0] = &keys[i];
        values[i] = utils.hash(leaf[0]);
        leaf[1] = &values[i];
    }

    // h(h(h(h(h()))), h(h(h(h([0]), h([1]), h([2]), h([3]), h([4]), h([5]), h([6]), h([7]), h([8]), h([9])))))
    const entries = [_]Entry{
        .{ &[_]u8{
            0x00,
        }, &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
        .{ &[_]u8{ 0x00, 0 }, &utils.parseHash("6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d") },
        .{ &[_]u8{ 0x00, 1 }, &utils.parseHash("4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a") },
        .{ &[_]u8{ 0x00, 2 }, &utils.parseHash("dbc1b4c900ffe48d575b5da5c638040125f65db0fe3e24494b76ea986457d986") },
        .{ &[_]u8{ 0x00, 3 }, &utils.parseHash("084fed08b978af4d7d196a7446a86b58009e636b611db16211b65a9aadff29c5") },
        .{ &[_]u8{ 0x00, 4 }, &utils.parseHash("e52d9c508c502347344d8c07ad91cbd6068afc75ff6292f062a09ca381c89e71") },
        .{ &[_]u8{ 0x00, 5 }, &utils.parseHash("e77b9a9ae9e30b0dbdb6f510a264ef9de781501d7b6b92ae89eb059c5ab743db") },
        .{ &[_]u8{ 0x00, 6 }, &utils.parseHash("67586e98fad27da0b9968bc039a1ef34c939b9b8e523a8bef89d478608c5ecf6") },
        .{ &[_]u8{ 0x00, 7 }, &utils.parseHash("ca358758f6d27e6cf45272937977a748fd88391db679ceda7dc7bf1f005ee879") },
        .{ &[_]u8{ 0x00, 8 }, &utils.parseHash("beead77994cf573341ec17b58bbf7eb34d2711c993c1d976b128b3188dc1829a") },
        .{ &[_]u8{ 0x00, 9 }, &utils.parseHash("2b4c342f5433ebe591a1da77e013d1b72475562d48578dca8b84bac6651c3cb9") },

        .{ &[_]u8{
            0x01,
        }, &utils.parseHash("5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456") },
        .{ &[_]u8{ 0x01, 0 }, &utils.parseHash("efbbac93ea2214b91bc2512d54c6b2a7237d60ac7263c64e1df4fce8f605f229") },

        .{ &[_]u8{
            0x02,
        }, &utils.parseHash("aa6ac2d4961882f42a345c7615f4133dde8e6d6e7c1b6b40ae4ff6ee52c393d0") },
        .{ &[_]u8{ 0x02, 0 }, &utils.parseHash("d3593f844c700825cb75d0b1c2dd033f9cf7623b5e9e270dd6b75cefabcfa20b") },

        .{ &[_]u8{
            0x03,
        }, &utils.parseHash("75d7682c8b5955557b2ef33654f31512b9b3edd17f74b5bf422ccabbd7537e1a") },
        .{ &[_]u8{ 0x03, 0 }, &utils.parseHash("061fb8732969d3389707024854489c09f63e607be4a0e0bbd2efe0453a314c8c") },

        .{ &[_]u8{
            0x04,
        }, &utils.parseHash("8993e2613264a79ff4b128414b0afe77afc26ae4574cee9269fe73ba85119c45") },

        .{ &constants.METADATA_KEY, &[_]u8{ constants.DATABASE_VERSION, 0x04, 0x03, 0x04 } },
    };

    try lmdb.expectEqualEntries(env, &entries);
}
