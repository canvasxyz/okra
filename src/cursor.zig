const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");

const utils = @import("utils.zig");
const skip_list = @import("skip_list.zig");

pub const Node = struct {
    level: u8,
    key: ?[]const u8,
    hash: *const [32]u8,
};

pub fn Cursor(
    comptime Transaction: type,
    comptime getTransaction: fn (txn: *const Transaction) lmdb.Transaction,
    comptime variant: utils.Variant,
) type {
    return struct {
        const Self = @This();

        cursor: lmdb.Cursor,
        key: std.ArrayList(u8),

        pub fn open(allocator: std.mem.Allocator, txn: *const Transaction) !Self {
            var iterator: Self = undefined;
            try iterator.init(allocator, txn);
            return iterator;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, txn: *const Transaction) !void {
            self.cursor = try lmdb.Cursor.open(getTransaction(txn));
            self.key = std.ArrayList(u8).init(allocator);
            try self.setKey(0, &[_]u8{});
            try self.cursor.goToKey(self.key.items);
        }

        pub fn close(self: *Self) void {
            self.key.deinit();
            self.cursor.close();
        }

        pub fn root(self: *Self) !Node {
            try self.setKey(0xFF, null);
            try self.cursor.goToKey(self.key.items);
            const value = try self.cursor.getCurrentValue();
            const metadata = try utils.parseMetadata(value);
            try self.setKey(metadata.height, null);
            try self.cursor.goToKey(self.key.items);
            return try self.getCurrentNode();
        }

        pub fn seek(self: *Self, level: u8, key: ?[]const u8) !?Node {
            try self.setKey(level, key);
            if (try self.cursor.seek(self.key.items)) |k| {
                if (k.len > 0 and k[0] == level) {
                    return try self.getCurrentNode();
                }
            }

            return null;
        }

        pub fn next(self: *Self) !?Node {
            if (self.key.items.len == 0) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToNext()) |k| {
                if (k.len > 0 and k[0] == self.key.items[0]) {
                    return try self.getCurrentNode();
                }
            }

            return null;
        }

        pub fn previous(self: *Self) !?Node {
            if (self.key.items.len == 0) {
                return error.Uninitialized;
            }

            if (try self.cursor.goToPrevious()) |k| {
                if (k.len > 0 and k[0] == self.key.items[0]) {
                    return try self.getCurrentNode();
                }
            }

            return null;
        }

        fn setKey(self: *Self, level: u8, key: ?[]const u8) !void {
            if (key) |bytes| {
                try self.key.resize(1 + bytes.len);
                self.key.items[0] = level;
                std.mem.copy(u8, self.key.items[1..], bytes);
            } else {
                try self.key.resize(1);
                self.key.items[0] = level;
            }
        }

        fn getCurrentNode(self: *Self) !Node {
            const key = try self.cursor.getCurrentKey();
            if (key.len == 0) {
                return error.InvalidDatabase;
            }

            const value = try self.cursor.getCurrentValue();
            const hash = try utils.getNodeHash(variant, key[0], key[1..], value);
            return Node{
                .level = key[0],
                .key = if (key.len > 1) key[1..] else null,
                .hash = hash,
            };
        }
    };
}

const Entry = [2][]const u8;

const TestTransaction = struct {
    txn: lmdb.Transaction,

    pub fn getTransaction(self: *const TestTransaction) lmdb.Transaction {
        return self.txn;
    }
};

fn expectEqualNodes(expected: ?Node, actual: ?Node) !void {
    try expectEqual(expected == null, actual == null);
    if (expected) |expected_node| {
        if (actual) |actual_node| {
            try expectEqual(expected_node.level, actual_node.level);
            try expectEqual(expected_node.key == null, actual_node.key == null);
            if (expected_node.key) |expected_key| {
                if (actual_node.key) |actual_key| {
                    try expectEqualSlices(u8, expected_key, actual_key);
                }
            }

            try expectEqualSlices(u8, expected_node.hash, actual_node.hash);
        }
    }
}

test "Cursor (Map)" {
    const MapCursor = Cursor(TestTransaction, TestTransaction.getTransaction, utils.Variant.Map);

    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    var sl = try skip_list.SkipList.open(allocator, env, .{ .degree = 4, .variant = utils.Variant.Map });
    defer sl.deinit();

    {
        var txn = try lmdb.Transaction.open(env, .{ .read_only = false });
        errdefer txn.abort();

        var cursor = try lmdb.Cursor.open(txn);
        var i: u8 = 0;
        while (i < 10) : (i += 1) {
            const key = [_]u8{i};
            try sl.set(txn, cursor, &key, &utils.hash(&key));
        }

        try txn.commit();
    }

    // From the tests in skip_list.zig, we get this tree:
    // ...119c45 ...537e1a ...c393d0 ...4c9456 ...52b855 |
    //           ...314c8c ...cfa20b ...05f229 ...afa01d | 00
    //                                         ...85459a | 01
    //                                         ...57d986 | 02
    //                                         ...ff29c5 | 03
    //                                         ...c89e71 | 04
    //                                         ...b743db | 05
    //                                         ...c5ecf6 | 06
    //                                         ...5ee879 | 07
    //                                         ...c1829a | 08
    //                                         ...1c3cb9 | 09

    {
        const txn = try lmdb.Transaction.open(env, .{ .read_only = true });
        defer txn.abort();

        var cursor = try MapCursor.open(allocator, &TestTransaction{ .txn = txn });
        defer cursor.close();

        const root = try cursor.root();
        try expect(root.level == 4);

        try expectEqualNodes(null, try cursor.next());

        try expectEqualNodes(Node{
            .level = 3,
            .key = null,
            .hash = &utils.parseHash("75d7682c8b5955557b2ef33654f31512b9b3edd17f74b5bf422ccabbd7537e1a"),
        }, try cursor.seek(3, null));

        try expectEqualNodes(Node{
            .level = 3,
            .key = &[_]u8{0},
            .hash = &utils.parseHash("061fb8732969d3389707024854489c09f63e607be4a0e0bbd2efe0453a314c8c"),
        }, try cursor.next());

        try expectEqualNodes(null, try cursor.next());

        try expectEqualNodes(Node{
            .level = 2,
            .key = null,
            .hash = &utils.parseHash("aa6ac2d4961882f42a345c7615f4133dde8e6d6e7c1b6b40ae4ff6ee52c393d0"),
        }, try cursor.seek(2, null));

        try expectEqualNodes(Node{
            .level = 2,
            .key = &[_]u8{0},
            .hash = &utils.parseHash("d3593f844c700825cb75d0b1c2dd033f9cf7623b5e9e270dd6b75cefabcfa20b"),
        }, try cursor.next());

        try expectEqualNodes(null, try cursor.next());

        try expectEqualNodes(Node{
            .level = 0,
            .key = &[_]u8{2},
            .hash = &utils.parseHash("dbc1b4c900ffe48d575b5da5c638040125f65db0fe3e24494b76ea986457d986"),
        }, try cursor.seek(0, &[_]u8{2}));

        try expectEqualNodes(Node{
            .level = 0,
            .key = &[_]u8{1},
            .hash = &utils.parseHash("4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a"),
        }, try cursor.previous());

        try expectEqualNodes(Node{
            .level = 0,
            .key = &[_]u8{0},
            .hash = &utils.parseHash("6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"),
        }, try cursor.previous());

        try expectEqualNodes(Node{
            .level = 0,
            .key = null,
            .hash = &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        }, try cursor.previous());

        try expectEqualNodes(Node{
            .level = 0,
            .key = &[_]u8{8},
            .hash = &utils.parseHash("beead77994cf573341ec17b58bbf7eb34d2711c993c1d976b128b3188dc1829a"),
        }, try cursor.seek(0, &[_]u8{8}));

        try expectEqualNodes(Node{
            .level = 0,
            .key = &[_]u8{9},
            .hash = &utils.parseHash("2b4c342f5433ebe591a1da77e013d1b72475562d48578dca8b84bac6651c3cb9"),
        }, try cursor.next());

        try expectEqualNodes(null, try cursor.next());
    }
}
