const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");

const skip_list = @import("skip_list.zig");
const iterators = @import("iterators.zig");
const cursors = @import("cursors.zig");
const utils = @import("utils.zig");

pub const Set = struct {
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

        pub fn open(set: *Set, read_only: bool) !Transaction {
            var transaction: Transaction = undefined;
            try transaction.init(set, read_only);
            return transaction;
        }

        pub fn init(self: *Transaction, set: *Set, read_only: bool) !void {
            self.skip_list = if (read_only) null else &set.skip_list;
            self.txn = try lmdb.Transaction.open(set.env, .{ .read_only = read_only });
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

        pub fn add(self: *Transaction, value: []const u8, hash: ?*[32]u8) !void {
            if (self.skip_list) |sl| {
                var buffer: [32]u8 = undefined;
                Sha256.hash(value, &buffer, .{});
                try sl.set(self.txn, self.cursor, &buffer, value);
                if (hash) |ptr| {
                    std.mem.copy(u8, ptr, &buffer);
                }
            } else {
                return error.ReadOnly;
            }
        }

        pub fn get(self: *Transaction, hash: *const [32]u8) !?[]const u8 {
            return try self.skip_list.get(hash);
        }
    };

    pub const Entry = struct {
        value: []const u8,
        hash: *const [32]u8,
    };

    fn getEntry(key: []const u8, value: []const u8) Error!Entry {
        if (key.len != 32) {
            return Error.InvalidDatabase;
        } else {
            return .{ .hash = key[0..32], .value = value };
        }
    }

    fn getTransaction(self: *const Transaction) lmdb.Transaction {
        return self.txn;
    }

    pub const Iterator = iterators.Iterator(Transaction, getTransaction, Entry, Error, getEntry);
    pub const Cursor = cursors.Cursor(Transaction, getTransaction, utils.Variant.Set);

    allocator: std.mem.Allocator,
    env: lmdb.Environment,
    skip_list: skip_list.SkipList,

    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !*Set {
        const set = try allocator.create(Set);
        set.allocator = allocator;
        set.env = try lmdb.Environment.open(path, .{ .map_size = options.map_size });
        try set.skip_list.init(allocator, set.env, .{
            .degree = options.degree,
            .variant = utils.Variant.Set,
            .log = options.log,
        });

        return set;
    }

    pub fn close(self: *Set) void {
        self.env.close();
        self.skip_list.deinit();
    }
};

fn expectIterator(entries: []const Set.Entry, iterator: *Set.Iterator) !void {
    var i: usize = 0;
    while (try iterator.next()) |entry| : (i += 1) {
        try expect(i < entries.len);
        try expectEqualSlices(u8, entry.value, entries[i].value);
        try expectEqualSlices(u8, entry.hash, entries[i].hash);
    }

    try expect(i == entries.len);
}

test "Set.Iterator" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "set.okra");
    defer allocator.free(path);

    const set = try Set.open(allocator, path, .{});
    defer set.close();

    {
        var txn = try Set.Transaction.open(set, false);
        errdefer txn.abort();

        try txn.add("foo", null);
        try txn.add("bar", null);
        try txn.add("baz", null);

        var iterator = try Set.Iterator.open(allocator, &txn);
        defer iterator.close();

        // ordered by hash!
        const entries = [_]Set.Entry{
            .{ .value = "foo", .hash = &utils.parseHash("2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae") },
            .{ .value = "baz", .hash = &utils.parseHash("baa5a0964d3320fbc0c6a922140453c8513ea24ab8fd0577034804a967248096") },
            .{ .value = "bar", .hash = &utils.parseHash("fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9") },
        };

        try expectIterator(&entries, iterator);

        try txn.commit();
    }
}
