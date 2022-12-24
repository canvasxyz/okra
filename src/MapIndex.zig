const std = @import("std");
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");

const skip_list = @import("skip_list.zig");
const EntryIterator = @import("EntryIterator.zig").EntryIterator;
const utils = @import("utils.zig");
const cursor = @import("cursor.zig");

pub const MapIndex = struct {
    const Error = error{
        InvalidDatabase,
    };

    pub const Options = struct {
        degree: u8 = 32,
        map_size: usize = 10485760,
        log: ?std.fs.File.Writer = null,
    };

    pub const Transaction = struct {
        skip_list: ?*skip_list.SkipList,
        txn: lmdb.Transaction,
        cursor: lmdb.Cursor,

        pub fn open(map: *MapIndex, read_only: bool) !Transaction {
            var transaction: Transaction = undefined;
            try transaction.init(map, read_only);
            return transaction;
        }

        pub fn init(self: *Transaction, map: *MapIndex, read_only: bool) !void {
            self.skip_list = if (read_only) null else &map.skip_list;
            self.txn = try lmdb.Transaction.open(map.env, .{ .read_only = read_only });
            self.cursor = try lmdb.Cursor.open(self.txn);
        }

        pub fn commit(self: *Transaction) !void {
            if (self.skip_list != null) {
                self.skip_list = null;
                self.cursor.close();
                try self.txn.commit();
            } else {
                return error.ReadOnly;
            }
        }

        pub fn abort(self: *Transaction) void {
            self.skip_list = null;
            self.cursor.close();
            self.txn.abort();
        }

        pub fn set(self: *Transaction, key: []const u8, hash: *const [32]u8) !void {
            if (self.skip_list) |skip_list| {
                try skip_list.set(self.txn, self.cursor, key, hash);
            } else {
                return error.ReadOnly;
            }
        }

        pub fn get(self: *Transaction, key: []const u8) !?*const [32]u8 {
            if (try self.skip_list.get(key)) |value| {
                if (value.len != 32) {
                    return error.InvalidDatabase;
                }

                return value[0..32];
            } else {
                return null;
            }
        }
    };

    pub const Entry = struct {
        key: []const u8,
        hash: *const [32]u8,
    };

    fn getEntry(key: []const u8, value: []const u8) Error!Entry {
        if (value.len != 32) {
            return Error.InvalidDatabase;
        } else {
            return .{ .key = key, .hash = value[0..32] };
        }
    }

    fn getTransaction(self: *const Transaction) lmdb.Transaction {
        return self.txn;
    }

    pub const Iterator = EntryIterator(Transaction, getTransaction, Entry, Error, getEntry);
    pub const Cursor = cursor.Cursor(Transaction, getTransaction, utils.Variant.MapIndex);

    allocator: std.mem.Allocator,
    env: lmdb.Environment,
    skip_list: skip_list.SkipList,

    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !*MapIndex {
        const map_index = try allocator.create(MapIndex);
        map_index.allocator = allocator;
        map_index.env = try lmdb.Environment.open(path, .{ .map_size = options.map_size });
        try map_index.skip_list.init(allocator, map_index.env, .{
            .degree = options.degree,
            .variant = utils.Variant.MapIndex,
            .log = options.log,
        });

        return map_index;
    }

    pub fn close(self: *MapIndex) void {
        self.env.close();
        self.skip_list.deinit();
        self.allocator.destroy(self);
    }
};

fn expectIterator(entries: []const MapIndex.Entry, iterator: *MapIndex.Iterator) !void {
    var i: usize = 0;
    while (try iterator.next()) |entry| : (i += 1) {
        try expect(i < entries.len);
        try expectEqualSlices(u8, entry.key, entries[i].key);
        try expectEqualSlices(u8, entry.hash, entries[i].hash);
    }

    try expect(i == entries.len);
}

test "MapIndex.Iterator" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "map.okra");
    defer allocator.free(path);

    const map = try MapIndex.open(allocator, path, .{});
    defer map.close();

    {
        var txn = try MapIndex.Transaction.open(map, false);
        errdefer txn.abort();

        try txn.set("a", &utils.hash("foo"));
        try txn.set("b", &utils.hash("bar"));
        try txn.set("c", &utils.hash("baz"));

        var iterator = try MapIndex.Iterator.open(allocator, &txn);
        defer iterator.close();

        const entries = [_]MapIndex.Entry{
            .{ .key = "a", .hash = &utils.hash("foo") },
            .{ .key = "b", .hash = &utils.hash("bar") },
            .{ .key = "c", .hash = &utils.hash("baz") },
        };

        try expectIterator(&entries, &iterator);

        try txn.commit();
    }
}
