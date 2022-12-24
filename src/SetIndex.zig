const std = @import("std");
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");

const skip_list = @import("skip_list.zig");
const EntryIterator = @import("EntryIterator.zig").EntryIterator;
const utils = @import("utils.zig");
const cursor = @import("cursor.zig");

pub const SetIndex = struct {
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

        pub fn open(set: *SetIndex, read_only: bool) !Transaction {
            var transaction: Transaction = undefined;
            try transaction.init(set, read_only);
            return transaction;
        }

        pub fn init(self: *Transaction, set: *SetIndex, read_only: bool) !void {
            self.skip_list = if (read_only) null else &set.skip_list;
            self.txn = try lmdb.Transaction.open(set.env, .{ .read_only = read_only });
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

        pub fn add(self: *Transaction, hash: *const [32]u8) !void {
            if (self.skip_list) |skip_list| {
                try skip_list.set(self.txn, self.cursor, hash, &[_]u8{});
            } else {
                return error.ReadOnly;
            }
        }
    };

    pub const Entry = struct {
        hash: *const [32]u8,
    };

    fn getEntry(key: []const u8, value: []const u8) Error!Entry {
        if (key.len != 32 or value.len != 0) {
            return error.InvalidDatabase;
        } else {
            return .{ .hash = key[0..32] };
        }
    }

    fn getTransaction(self: *const Transaction) lmdb.Transaction {
        return self.txn;
    }

    pub const Iterator = EntryIterator(Transaction, getTransaction, Entry, Error, getEntry);
    pub const Cursor = cursor.Cursor(Transaction, getTransaction, utils.Variant.SetIndex);

    allocator: std.mem.Allocator,
    env: lmdb.Environment,
    skip_list: skip_list.SkipList,

    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !*SetIndex {
        const set_index = try allocator.create(SetIndex);
        set_index.allocator = allocator;
        set_index.env = try lmdb.Environment.open(path, .{ .map_size = options.map_size });
        try set_index.skip_list.init(allocator, set_index.env, .{
            .degree = options.degree,
            .variant = utils.Variant.SetIndex,
            .log = options.log,
        });

        return set_index;
    }

    pub fn close(self: *SetIndex) void {
        self.env.close();
        self.skip_list.deinit();
        self.allocator.destroy(self);
    }
};

fn expectIterator(entries: []const SetIndex.Entry, iterator: *SetIndex.Iterator) !void {
    var i: usize = 0;
    while (try iterator.next()) |entry| : (i += 1) {
        try expect(i < entries.len);
        try expectEqualSlices(u8, entry.hash, entries[i].hash);
    }

    try expect(i == entries.len);
}

test "SetIndex.Iterator" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "set.okra");
    defer allocator.free(path);

    const set_index = try SetIndex.open(allocator, path, .{});
    defer set_index.close();

    {
        var txn = try SetIndex.Transaction.open(set_index, false);
        errdefer txn.abort();

        try txn.add(&utils.parseHash("2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"));
        try txn.add(&utils.parseHash("fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9"));
        try txn.add(&utils.parseHash("baa5a0964d3320fbc0c6a922140453c8513ea24ab8fd0577034804a967248096"));

        var iterator = try SetIndex.Iterator.open(allocator, &txn);
        defer iterator.close();

        // ordered by hash!
        const entries = [_]SetIndex.Entry{
            .{ .hash = &utils.parseHash("2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae") },
            .{ .hash = &utils.parseHash("baa5a0964d3320fbc0c6a922140453c8513ea24ab8fd0577034804a967248096") },
            .{ .hash = &utils.parseHash("fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9") },
        };

        try expectIterator(&entries, &iterator);

        try txn.commit();
    }
}
