const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");

const SkipList = @import("SkipList.zig").SkipList;
const EntryIterator = @import("EntryIterator.zig").EntryIterator;
const utils = @import("utils.zig");

pub const Map = struct {
    const Error = error{
        InvalidDatabase,
    };

    pub const Options = struct {
        degree: u8 = 32,
        map_size: usize = 10485760,
        log: ?std.fs.File.Writer = null,
    };

    pub const Transaction = struct {
        skip_list: ?*SkipList,
        txn: lmdb.Transaction,
        cursor: lmdb.Cursor,

        pub fn open(map: *Map, read_only: bool) !Transaction {
            var transaction: Transaction = undefined;
            try transaction.init(map, read_only);
            return transaction;
        }

        pub fn init(self: *Transaction, map: *Map, read_only: bool) !void {
            self.skip_list = if (read_only) null else &map.skip_list;
            self.txn = try lmdb.Transaction.open(map.env, .{ .read_only = read_only });
            self.cursor = try lmdb.Cursor.open(self.txn);
        }

        pub fn commit(self: *Transaction) !void {
            if (self.skip_list == null) {
                return error.ReadOnly;
            }

            self.skip_list = null;
            self.cursor.close();
            try self.txn.commit();
        }

        pub fn abort(self: *Transaction) void {
            self.skip_list = null;
            self.cursor.close();
            self.txn.abort();
        }

        pub fn set(self: *Transaction, key: []const u8, value: []const u8, hash: ?*[32]u8) !void {
            if (self.skip_list) |skip_list| {
                const buffer = try skip_list.allocator.alloc(u8, 32 + value.len);
                Sha256.hash(value, buffer[0..32], .{});
                std.mem.copy(u8, buffer[32..], value);
                try skip_list.set(self.txn, self.cursor, key, buffer);
                if (hash) |ptr| {
                    std.mem.copy(u8, ptr, buffer[0..32]);
                }
            } else {
                return error.ReadOnly;
            }
        }

        pub fn get(self: *Transaction, key: []const u8, hash: ?*[32]u8) ![]const u8 {
            if (try self.skip_list.get(self.txn, key)) |value| {
                if (value.len < 32) {
                    return error.InvalidDatabase;
                }

                if (hash) |ptr| {
                    std.mem.copy(u8, ptr, value[0..32]);
                }

                return value[32..];
            } else {
                return null;
            }
        }
    };

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
        hash: *const [32]u8,
    };

    fn getEntry(key: []const u8, value: []const u8) Error!Entry {
        if (value.len < 32) {
            return error.InvalidDatabase;
        } else {
            return .{ .key = key, .value = value[32..], .hash = value[0..32] };
        }
    }

    pub const Iterator = EntryIterator(Entry, Error, getEntry);

    env: lmdb.Environment,
    skip_list: SkipList,

    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !Map {
        var map: Map = undefined;
        try map.init(allocator, path, options);
        return map;
    }

    pub fn init(self: *Map, allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void {
        self.env = try lmdb.Environment.open(path, .{ .map_size = options.map_size });
        try self.skip_list.init(allocator, self.env, .{
            .degree = options.degree,
            .variant = utils.Variant.Map,
            .log = options.log,
        });
    }

    pub fn close(self: *Map) void {
        self.env.close();
        self.skip_list.deinit();
    }
};

fn expectIterator(entries: []const Map.Entry, iterator: *Map.Iterator) !void {
    var i: usize = 0;
    while (try iterator.next()) |entry| : (i += 1) {
        try expect(i < entries.len);
        try expectEqualSlices(u8, entry.key, entries[i].key);
        try expectEqualSlices(u8, entry.value, entries[i].value);
        try expectEqualSlices(u8, entry.hash, entries[i].hash);
    }

    try expect(i == entries.len);
}

test "Map.Iterator" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "map.okra");
    defer allocator.free(path);

    var map = try Map.open(allocator, path, .{});
    defer map.close();

    {
        var txn = try Map.Transaction.open(&map, false);
        errdefer txn.abort();

        try txn.set("a", "foo", null);
        try txn.set("b", "bar", null);
        try txn.set("c", "baz", null);

        var iterator = try Map.Iterator.open(allocator, txn.txn);
        defer iterator.close();

        const entries = [_]Map.Entry{
            .{ .key = "a", .value = "foo", .hash = &utils.hash("foo") },
            .{ .key = "b", .value = "bar", .hash = &utils.hash("bar") },
            .{ .key = "c", .value = "baz", .hash = &utils.hash("baz") },
        };

        try expectIterator(&entries, &iterator);

        try txn.commit();
    }
}
