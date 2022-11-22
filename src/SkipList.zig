const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");

const SkipListCursor = @import("./SkipListCursor.zig").SkipListCursor;

const utils = @import("./utils.zig");
const constants = @import("./constants.zig");
const printTree = @import("./print.zig").printTree;

pub const SkipList = struct {
    allocator: std.mem.Allocator,
    limit: u8,
    env: lmdb.Environment,
    log_writer: ?std.fs.File.Writer,
    log_prefix: std.ArrayList(u8),
    target_keys: std.ArrayList(std.ArrayList(u8)),
    new_siblings: std.ArrayList([]const u8),
    value_buffer: [32]u8 = undefined,

    pub const Error = error {
        UnsupportedVersion,
        InvalidDatabase,
        InvalidFanoutDegree,
        Duplicate,
        InsertError,
    };

    pub const Options = struct {
        degree: u8 = 32,
        map_size: usize = 10485760,
        variant: utils.Variant = utils.Variant.UnorderedSet,
        log: ?std.fs.File.Writer = null,
    };
    
    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !SkipList {
        const env = try lmdb.Environment.open(path, .{ .map_size = options.map_size });

        var skip_list = SkipList {
            .allocator = allocator,
            .limit = @intCast(u8, 256 / @intCast(u16, options.degree)),
            .env = env,
            .log_writer = options.log,
            .log_prefix = std.ArrayList(u8).init(allocator),
            .target_keys = std.ArrayList(std.ArrayList(u8)).init(allocator),
            .new_siblings = std.ArrayList([]const u8).init(allocator),
        };

        // Initialize the metadata and root entries if necessary
        const txn = try lmdb.Transaction.open(env, false);
        errdefer txn.abort();

        if (try utils.getMetadata(txn)) |metadata| {
            if (metadata.degree != options.degree) {
                return error.InvalidDegree;
            } else if (metadata.variant != options.variant) {
                return error.InvalidVariant;
            }
        } else {
            Sha256.hash(&[0]u8 { }, &skip_list.value_buffer, .{});
            try txn.set(&[_]u8 { 0, 0 }, &skip_list.value_buffer);
            try utils.setMetadata(txn, .{ .degree = options.degree, .variant = options.variant, .height = 0 });
            try txn.commit();
        }

        return skip_list;
    }
    
    pub fn close(self: *SkipList) void {
        self.env.close();
        self.log_prefix.deinit();

        for (self.target_keys.items) |key| key.deinit();
        self.target_keys.deinit();
        self.new_siblings.deinit();
    }

    fn allocate(self: *SkipList, height: u16) !void {
        try self.log_prefix.resize(0);
        try self.new_siblings.resize(0);

        const target_keys_len = self.target_keys.items.len;
        if (target_keys_len < height) {
            try self.target_keys.resize(height);
            for (self.target_keys.items[target_keys_len..]) |*key| {
                key.* = std.ArrayList(u8).init(self.allocator);
            }
        }
    }
    
    const InsertResult = enum { delete, update };

    pub fn insert(self: *SkipList, cursor: *SkipListCursor, key: []const u8, value: []const u8) !void {
        try self.log("insert({s}, {s})", .{ hex(key), hex(value) });

        var metadata = try utils.getMetadata(cursor.txn) orelse return error.InvalidDatabase;
        try self.log("height: {d}\n", .{ metadata.height });
        try self.allocate(metadata.height);

        try self.log_prefix.appendSlice("| ");

        const result = try switch (metadata.height) {
            0 => self.insertLeaf(cursor, key, value),
            else => self.insertNode(cursor, 1, metadata.height - 1, &[_]u8 {}, key, value),
        };

        try self.log_prefix.resize(0);
        
        var root_level = if (metadata.height == 0) 1 else metadata.height;
        var root_value = try switch (result) {
            .delete => error.InsertError,
            .update => self.hashRange(cursor, root_level, &[_]u8 {}),
        };

        try self.log("new root: {d} @ {s}", .{ root_level, hex(root_value) });
        try cursor.set(root_level, &[_]u8 { }, root_value);

        try self.log("new_children: {d}", .{ self.new_siblings.items.len });
        for (self.new_siblings.items) |child| try self.log("- {s}", .{ hex(child) });

        while (self.new_siblings.items.len > 0) {
            try self.promote(cursor, root_level);

            // actually the same value over and over, but whatever
            root_level += 1;
            root_value = try self.hashRange(cursor, root_level, &[_]u8 {});
            try self.log("new root: {d} @ {s}", .{ root_level, hex(root_value) });
            try cursor.set(root_level, &[_]u8 { },root_value);

            try self.log("new_children: {d}", .{ self.new_siblings.items.len });
            for (self.new_siblings.items) |child| try self.log("- {s}", .{ hex(child) });
        }

        try cursor.goToNode(root_level, &[_]u8 { });
        while (root_level > 0) : (root_level -= 1) {
            const last_key = try cursor.goToLast(root_level - 1);
            if (last_key.len > 0) {
                break;
            } else {
                try self.log("trim root from {d} to {d}", .{ root_level, root_level - 1 });
                try cursor.delete(root_level, &[_]u8 { });
            }
        }

        try self.log("writing metadata entry with height {d}", .{ root_level });
        metadata.height = root_level;
        try utils.setMetadata(cursor.txn, metadata);
    }

    fn insertNode(
        self: *SkipList,
        cursor: *SkipListCursor,
        depth: u16,
        level: u16,
        first_child: []const u8,
        key: []const u8,
        value: []const u8,
    ) !InsertResult {
        if (first_child.len == 0) {
            try self.log("insertNode({d}, null, {s}, {s})", .{ level, hex(key), hex(value) });
        } else {
            try self.log("insertNode({d}, {s}, {s}, {s})", .{ level, hex(first_child), hex(key), hex(value) });
        }

        if (std.mem.eql(u8, key, first_child)) {
            return Error.Duplicate;
        }
        
        assert(std.mem.lessThan(u8, first_child, key));
        
        if (level == 0) {
            try cursor.set(0, key, value);
            if (self.isSplit(value)) {
                try self.new_siblings.append(key);
            }

            return InsertResult.update;
        }

        const target = try self.findTargetKey(cursor, level, first_child, key);
        if (target.len == 0) {
            try self.log("target: null", .{ });
        } else {
            try self.log("target: {s}", .{ hex(target) });
        }

        const is_left_edge = first_child.len == 0;
        try self.log("is_left_edge: {any}", .{ is_left_edge });

        const is_first_child = std.mem.eql(u8, target, first_child);
        try self.log("is_first_child: {any}", .{ is_first_child });

        try self.log_prefix.appendSlice("| ");

        const result = try self.insertNode(cursor, depth + 1, level - 1, target, key, value);
        switch (result) {
            InsertResult.delete => try self.log("result: delete", .{ }),
            InsertResult.update => try self.log("result: update", .{}),
        }
    
        try self.log_prefix.resize(depth * 2);

        try self.log("new siblings: {d}", .{ self.new_siblings.items.len });
        for (self.new_siblings.items) |child|
            try self.log("- {s}", .{ hex(child) });

        switch (result) {
            InsertResult.delete => {
                assert(!is_left_edge or !is_first_child);

                // delete the entry and move to the previous child
                // previous_child is the slice at target_keys[level - 1].items
                const previous_child = try self.moveToPreviousChild(cursor, level);
                if (previous_child.len == 0) {
                    try self.log("previous_child: null", .{ });
                } else {
                    try self.log("previous_child: {s}", .{ hex(previous_child) });
                }

                try self.promote(cursor, level);

                const previous_child_value = try self.hashRange(cursor, level, previous_child);
                try cursor.set(level, previous_child, previous_child_value);
                
                if (is_first_child or std.mem.lessThan(u8, previous_child, first_child)) {
                    if (self.isSplit(previous_child_value)) {
                        try self.new_siblings.append(previous_child);
                    }

                    return InsertResult.delete;
                } else if (std.mem.eql(u8, previous_child, first_child)) {
                    if (is_left_edge or self.isSplit(previous_child_value)) {
                        return InsertResult.update;
                    } else {
                        return InsertResult.delete;
                    }
                } else {
                    if (self.isSplit(previous_child_value)) {
                        try self.new_siblings.append(target);
                    }

                    return InsertResult.update;
                }
            },
            InsertResult.update => {
                const target_value = try self.hashRange(cursor, level, target);
                try cursor.set(level, target, target_value);

                const is_target_split = self.isSplit(target_value);
                try self.log("is_target_split: {any}", .{ is_target_split });
                
                try self.promote(cursor, level);
            
                // is_first_child means either target's original value was a split,
                // or is_left_edge is true.
                if (is_first_child) {
                    if (is_target_split or is_left_edge) {
                        return InsertResult.update;
                    } else {
                        return InsertResult.delete;
                    }
                } else {
                    if (is_target_split) {
                        try self.new_siblings.append(target);
                    }

                    return InsertResult.update;
                }
            }
        }
    }

    fn insertLeaf(self: *SkipList,
        cursor: *SkipListCursor,
        key: []const u8,
        value: []const u8,
    ) !InsertResult {
        try cursor.set(0, key, value);

        if (self.isSplit(value)) {
            try self.new_siblings.append(key);
        }

        return InsertResult.update;
    }
    
    fn findTargetKey(
        self: *SkipList,
        cursor: *SkipListCursor,
        level: u16,
        first_child: []const u8,
        key: []const u8,
    ) ![]const u8 {
        assert(level > 0);
        const target = &self.target_keys.items[level - 1];
        try utils.copy(target, first_child);

        try cursor.goToNode(level, first_child);
        while (try cursor.goToNext()) |next_child| {
            if (std.mem.lessThan(u8, key, next_child)) {
                return target.items;
            } else {
                try utils.copy(target, next_child);
            }
        }

        return target.items;
    }

    fn moveToPreviousChild(self: *SkipList, cursor: *SkipListCursor, level: u16) ![]const u8 {
        const target = &self.target_keys.items[level - 1];

        // delete the entry and move to the previous child
        try cursor.goToNode(level, target.items);
        try cursor.deleteCurrentKey();
        while (try cursor.goToPrevious()) |previous_child| {
            if (previous_child.len == 0) {
                try target.resize(0);
                return target.items;
            } else if (try cursor.get(level - 1, previous_child)) |previous_grand_child_value| {
                if (self.isSplit(previous_grand_child_value)) {
                    try utils.copy(target, previous_child);
                    return target.items;
                }
            }

            try cursor.deleteCurrentKey();
        }

        return Error.InsertError;
    }
    
    // hashRange returns a pointer to self.value_buffer
    fn hashRange(self: *SkipList, cursor: *SkipListCursor, level: u16, key: []const u8) ![]const u8 {
        if (key.len == 0) {
            try self.log("hashRange({d}, null)", .{ level });
        } else {
            try self.log("hashRange({d}, {s})", .{ level, hex(key) });
        }
        
        try cursor.goToNode(level - 1, key);
        var digest = Sha256.init(.{});
        
        const value = try cursor.getCurrentValue();
        try self.log("- hashing {s} <- {s}", .{ hex(value), hex(key) });
        digest.update(value);

        while (try cursor.goToNext()) |next_key| {
            const next_value = try cursor.getCurrentValue();
            if (self.isSplit(next_value)) break;
            try self.log("- hashing {s} <- {s}", .{ hex(next_value), hex(next_key) });
            digest.update(next_value);
        }

        digest.final(&self.value_buffer);
        try self.log("--------- {s}", .{ hex(&self.value_buffer) });
        return &self.value_buffer;
    }

    fn promote(self: *SkipList, cursor: *SkipListCursor, level: u16) !void {
        var old_index: usize = 0;
        var new_index: usize = 0;
        const new_sibling_count = self.new_siblings.items.len;
        while (old_index < new_sibling_count) : (old_index += 1) {
            const key = self.new_siblings.items[old_index];
            const value = try self.hashRange(cursor, level, key);
            try cursor.set(level, key, value);
            if (self.isSplit(value)) {
                self.new_siblings.items[new_index] = key;
                new_index += 1;
            }
        }

        try self.new_siblings.resize(new_index);
    }

    fn isSplit(self: *const SkipList, value: []const u8) bool {
        return value[value.len - 1] < self.limit;
    }

    fn log(self: *const SkipList, comptime format: []const u8, args: anytype) !void {
        if (self.log_writer) |writer| {
            try writer.print("{s}", .{ self.log_prefix.items });
            try writer.print(format ++ "\n", args);
        }
    }
};

const Entry = [2][]const u8;

test "SkipList()" {
    const allocator = std.heap.c_allocator;
    
    const log = std.io.getStdErr().writer();
    try log.print("\n", .{});
    
    var tmp = std.testing.tmpDir(.{});
    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    var skip_list = try SkipList.open(allocator, path, .{ });
    defer skip_list.close();

    try lmdb.expectEqualEntries(skip_list.env, &[_]Entry {
        .{ &[_]u8 { 0x00, 0x00      }, &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
        .{ &[_]u8 { 0xFF, 0xFF }, &[_]u8 { 0x01, 0x20, 0x00, 0x00, 0x00 } },
    });
}

test "SkipList(a, b, c)" {
    const allocator = std.heap.c_allocator;
    const log = std.io.getStdErr().writer();
    try log.print("\n", .{});

    var tmp = std.testing.tmpDir(.{});
    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    var skip_list = try SkipList.open(allocator, path, .{ .degree = 4 });
    defer skip_list.close();

    var cursor = try SkipListCursor.open(allocator, skip_list.env, false);
    {
        errdefer cursor.abort();
        try skip_list.insert(&cursor, "a", &utils.hash("foo"));
        try skip_list.insert(&cursor, "b", &utils.hash("bar"));
        try skip_list.insert(&cursor, "c", &utils.hash("baz"));
    }

    try cursor.commit();

    try lmdb.expectEqualEntries(skip_list.env, &[_]Entry {
        .{ &[_]u8 { 0x00, 0x00      }, &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
        .{ &[_]u8 { 0x00, 0x00, 'a' }, &utils.parseHash("2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae") },
        .{ &[_]u8 { 0x00, 0x00, 'b' }, &utils.parseHash("fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9") },
        .{ &[_]u8 { 0x00, 0x00, 'c' }, &utils.parseHash("baa5a0964d3320fbc0c6a922140453c8513ea24ab8fd0577034804a967248096") },
        .{ &[_]u8 { 0x00, 0x01      }, &utils.parseHash("1ca9140a5b30b5576694b7d45ce1af298d858a58dfa2376302f540ee75a89348") },
        .{ &[_]u8 { 0xFF, 0xFF      }, &[_]u8 { 0x01, 0x04, 0x00, 0x00, 0x01 } },
    });
}

test "SkipList(10)" {
    const allocator = std.heap.c_allocator;
    const log = std.io.getStdErr().writer();
    try log.print("\n", .{});

    var tmp = std.testing.tmpDir(.{});
    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    var skip_list = try SkipList.open(allocator, path, .{ .degree = 4 });
    defer skip_list.close();

    // try log.print("----------------------------------------------------------------\n", .{});

    {
        var i: u8 = 0;
        while (i < 10) : (i += 1) {
            const key = [_]u8 { i };
            var cursor = try SkipListCursor.open(allocator, skip_list.env, false);
            errdefer cursor.abort();
            try skip_list.insert(&cursor, &key, &utils.hash(&key));
            try cursor.commit();
            // try printTree(allocator, skip_list.env, log, .{ .compact = true });
        }
    }


    var keys: [10][1]u8 = undefined;
    var values: [10][32]u8 = undefined;
    var leaves: [10]Entry = undefined;
    for (leaves) |*leaf, i| {
        keys[i] = .{ @intCast(u8, i) };
        leaf[0] = &keys[i];
        values[i] = utils.hash(leaf[0]);
        leaf[1] = &values[i];
    }

    // h(h(h(h(h()))), h(h(h(h([0]), h([1]), h([2]), h([3]), h([4]), h([5]), h([6]), h([7]), h([8]), h([9])))))
    const entries = [_]Entry {
        .{ &[_]u8 { 0x00, 0x00    }, &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
        .{ &[_]u8 { 0x00, 0x00, 0 }, &utils.parseHash("6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d") },
        .{ &[_]u8 { 0x00, 0x00, 1 }, &utils.parseHash("4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a") },
        .{ &[_]u8 { 0x00, 0x00, 2 }, &utils.parseHash("dbc1b4c900ffe48d575b5da5c638040125f65db0fe3e24494b76ea986457d986") },
        .{ &[_]u8 { 0x00, 0x00, 3 }, &utils.parseHash("084fed08b978af4d7d196a7446a86b58009e636b611db16211b65a9aadff29c5") },
        .{ &[_]u8 { 0x00, 0x00, 4 }, &utils.parseHash("e52d9c508c502347344d8c07ad91cbd6068afc75ff6292f062a09ca381c89e71") },
        .{ &[_]u8 { 0x00, 0x00, 5 }, &utils.parseHash("e77b9a9ae9e30b0dbdb6f510a264ef9de781501d7b6b92ae89eb059c5ab743db") },
        .{ &[_]u8 { 0x00, 0x00, 6 }, &utils.parseHash("67586e98fad27da0b9968bc039a1ef34c939b9b8e523a8bef89d478608c5ecf6") },
        .{ &[_]u8 { 0x00, 0x00, 7 }, &utils.parseHash("ca358758f6d27e6cf45272937977a748fd88391db679ceda7dc7bf1f005ee879") },
        .{ &[_]u8 { 0x00, 0x00, 8 }, &utils.parseHash("beead77994cf573341ec17b58bbf7eb34d2711c993c1d976b128b3188dc1829a") },
        .{ &[_]u8 { 0x00, 0x00, 9 }, &utils.parseHash("2b4c342f5433ebe591a1da77e013d1b72475562d48578dca8b84bac6651c3cb9") },

        .{ &[_]u8 { 0x00, 0x01,   }, &utils.parseHash("5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456") },
        .{ &[_]u8 { 0x00, 0x01, 0 }, &utils.parseHash("efbbac93ea2214b91bc2512d54c6b2a7237d60ac7263c64e1df4fce8f605f229") },
        
        .{ &[_]u8 { 0x00, 0x02,   }, &utils.parseHash("aa6ac2d4961882f42a345c7615f4133dde8e6d6e7c1b6b40ae4ff6ee52c393d0") },
        .{ &[_]u8 { 0x00, 0x02, 0 }, &utils.parseHash("d3593f844c700825cb75d0b1c2dd033f9cf7623b5e9e270dd6b75cefabcfa20b") },
        
        .{ &[_]u8 { 0x00, 0x03,   }, &utils.parseHash("75d7682c8b5955557b2ef33654f31512b9b3edd17f74b5bf422ccabbd7537e1a") },
        .{ &[_]u8 { 0x00, 0x03, 0 }, &utils.parseHash("061fb8732969d3389707024854489c09f63e607be4a0e0bbd2efe0453a314c8c") },

        .{ &[_]u8 { 0x00, 0x04,   }, &utils.parseHash("8993e2613264a79ff4b128414b0afe77afc26ae4574cee9269fe73ba85119c45") },
        .{ &[_]u8 { 0xFF, 0xFF    }, &[_]u8 { 0x01, 0x04, 0x00, 0x00, 0x04 } },
    };

    try lmdb.expectEqualEntries(skip_list.env, &entries);
}