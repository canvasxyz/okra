const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("lmdb");

const utils = @import("./utils.zig");
const printTree = @import("./print.zig").printTree;
const printEntries = @import("./print.zig").printEntries;

const allocator = std.heap.c_allocator;

/// A Builder is naive bottom-up tree builder used to construct large trees
/// at once and for reference when unit testing the actual Tree.
/// Create a builder with Builder.init(path, options), insert as many leaves
/// as you want using .set(key, value), and then call .commit().
/// Builder is also used in the rebuild cli command.
pub const Builder = struct {
    const Options = struct {
        degree: u8 = 32,
        variant: utils.Variant = utils.Variant.UnorderedSet,
    };

    txn: lmdb.Transaction,
    key: std.ArrayList(u8),
    value: [32]u8 = undefined,
    limit: u8,
    options: Options,
    
    pub fn init(env: lmdb.Environment, options: Options) !Builder {
        const txn = try lmdb.Transaction.open(env, false);
        errdefer txn.abort();
        
        const key = std.ArrayList(u8).init(allocator);
        const limit = @intCast(u8, 256 / @intCast(u16, options.degree));
        var builder = Builder { .txn = txn, .key = key, .limit = limit, .options = options };

        Sha256.hash(&[0]u8 { }, &builder.value, .{});
        try txn.set(&[_]u8 { 0x00, 0x00 }, &builder.value);
        return builder;
    }
    
    pub fn set(self: *Builder, key: []const u8, value: []const u8) !void {
        try self.setKey(0, key);
        try self.txn.set(self.key.items, value);
    }

    pub fn commit(self: *Builder) !void {
        defer self.key.deinit();

        var cursor = try lmdb.Cursor.open(self.txn);
        try cursor.goToKey(&[_]u8 { 0, 0 });

        var level: u16 = 0;
        const height = while (true) : (level += 1) {
            const count = try self.buildLevel(cursor, level);
            if (count == 0) {
                break level;
            } else if (count == 1) {
                break level + 1;
            }
        };

        cursor.close();

        try utils.setMetadata(self.txn, .{
            .degree = self.options.degree,
            .variant = self.options.variant,
            .height = height,
        });

        try self.txn.commit();
    }
    
    pub fn abort(self: *Builder) void {
        self.key.deinit();
        self.txn.abort();
    }
    
    fn buildLevel(self: *Builder, cursor: lmdb.Cursor, level: u16) !usize {
        var parent_count: usize = 0;
        var child_count: usize = 0;

        {
            const key = try cursor.getCurrentKey();
            assert(key.len == 2);
            assert(utils.getLevel(key) == level);
        }
        
        var hash = Sha256.init(.{});
        hash.update(try cursor.getCurrentValue());

        try self.setKey(level + 1, &[_]u8 {});
        while (try cursor.goToNext()) |key| {
            if (utils.getLevel(key) != level) break;

            child_count += 1;
            const value = try cursor.getCurrentValue();

            if (self.isSplit(value)) {
                hash.final(&self.value);
                try self.txn.set(self.key.items, &self.value);
                parent_count += 1;

                try self.setKey(level + 1, key[2..]);
                hash = Sha256.init(.{});
                hash.update(value);
            } else {
                hash.update(value);
            }
        }
        
        if (child_count == 0) {
            return 0;
        }
        
        hash.final(&self.value);
        try self.txn.set(self.key.items, &self.value);
        return parent_count + 1;
    }
    
    fn setKey(self: *Builder, level: u16, key: []const u8) !void {
        try self.key.resize(2 + key.len);
        utils.setLevel(self.key.items, level);
        std.mem.copy(u8, self.key.items[2..], key);
    }
    
    fn isSplit(self: *const Builder, value: []const u8) bool {
        return value[value.len - 1] < self.limit;
    }
};


var path_buffer: [4096]u8 = undefined;

const Entry = [2][]const u8;

fn testEntryList(leaves: []const Entry, entries: []const Entry, options: Builder.Options) !void {
    const log = std.io.getStdErr().writer();
    try log.print("\n", .{});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    
    var tmp_path = try tmp.dir.realpath(".", &path_buffer);

    const path = try std.fs.path.joinZ(allocator, &.{ tmp_path, "data.mdb" });
    defer allocator.free(path);
    
    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    var builder = try Builder.init(env, options);

    for (leaves) |leaf| try builder.set(leaf[0], leaf[1]);

    try builder.commit();

    // try log.print("----------------------------------------------------------------\n", .{});
    // try printEntries(env, log);

    try lmdb.expectEqualEntries(env, entries);

    // try log.print("----------------------------------------------------------------\n", .{});
    // try printTree(allocator, env, log, .{ .compact = true });
}

test "Builder()" {
    const leaves = [_]Entry { };

    const entries = [_]Entry {
        .{ &[_]u8 { 0x00, 0x00 }, &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
        .{ &[_]u8 { 0xFF, 0xFF }, &[_]u8 { 0x01, 0x20, 0x00, 0x00, 0x00 } },
    };

    try testEntryList(&leaves, &entries, .{ });
}

test "Builder(a, b, c)" {
    const leaves = [_]Entry {
        .{ "a", &utils.hash("foo") },
        .{ "b", &utils.hash("bar") },
        .{ "c", &utils.hash("baz") },
    };

    const entries = [_]Entry {
        .{ &[_]u8 { 0x00, 0x00      }, &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
        .{ &[_]u8 { 0x00, 0x00, 'a' }, &utils.parseHash("2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae") },
        .{ &[_]u8 { 0x00, 0x00, 'b' }, &utils.parseHash("fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9") },
        .{ &[_]u8 { 0x00, 0x00, 'c' }, &utils.parseHash("baa5a0964d3320fbc0c6a922140453c8513ea24ab8fd0577034804a967248096") },

        .{ &[_]u8 { 0x00, 0x01      }, &utils.parseHash("1ca9140a5b30b5576694b7d45ce1af298d858a58dfa2376302f540ee75a89348") },
        .{ &[_]u8 { 0xFF, 0xFF      }, &[_]u8 { 0x01, 0x04, 0x00, 0x00, 0x01 } },
    };

    try testEntryList(&leaves, &entries, .{ .degree = 4 });
}

test "Builder(a, b, c, d)" {
    const leaves = [_]Entry {
        .{ "a", &utils.hash("foo") },
        .{ "b", &utils.hash("bar") },
        .{ "c", &utils.hash("baz") },
        .{ "d", &utils.hash("wow") },
    };

    const entries = [_]Entry {
        .{ &[_]u8 { 0x00, 0x00      }, &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
        .{ &[_]u8 { 0x00, 0x00, 'a' }, &utils.parseHash("2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae") },
        .{ &[_]u8 { 0x00, 0x00, 'b' }, &utils.parseHash("fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9") },
        .{ &[_]u8 { 0x00, 0x00, 'c' }, &utils.parseHash("baa5a0964d3320fbc0c6a922140453c8513ea24ab8fd0577034804a967248096") },
        .{ &[_]u8 { 0x00, 0x00, 'd' }, &utils.parseHash("b6dc933311bc2357cc5fc636a4dbe41a01b7a33b583d043a7f870f3440697e27") },

        .{ &[_]u8 { 0x00, 0x01      }, &utils.parseHash("1ca9140a5b30b5576694b7d45ce1af298d858a58dfa2376302f540ee75a89348") },
        .{ &[_]u8 { 0x00, 0x01, 'd' }, &utils.parseHash("9171bd83fa38f12d3b2df9bd02ba891aafb00dcca723e3ed6820492ba9d7284e") },

        .{ &[_]u8 { 0x00, 0x02,     }, &utils.parseHash("d31d890779b01bfa5d949717d89dedc097902ef468ca04b8290d0a032e562f0a") },
        .{ &[_]u8 { 0xFF, 0xFF      }, &[_]u8 { 0x01, 0x04, 0x00, 0x00, 0x02 } },
    };

    try testEntryList(&leaves, &entries, .{ .degree = 4 });
}

test "Builder(a, b, c, d, e)" {
    const leaves = [_]Entry {
        .{ "a", &utils.hash("foo") },
        .{ "b", &utils.hash("bar") },
        .{ "c", &utils.hash("baz") },
        .{ "d", &utils.hash("wow") },
        .{ "e", &utils.hash("ooo") },
    };

    // h(h(h(h(h(h(), h('foo'), h('bar'), h('baz'))))), h(h(h(h(h('wow'), h('ooo'))))))
    const entries = [_]Entry {
        .{ &[_]u8 { 0x00, 0x00      }, &utils.parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
        .{ &[_]u8 { 0x00, 0x00, 'a' }, &utils.parseHash("2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae") },
        .{ &[_]u8 { 0x00, 0x00, 'b' }, &utils.parseHash("fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9") },
        .{ &[_]u8 { 0x00, 0x00, 'c' }, &utils.parseHash("baa5a0964d3320fbc0c6a922140453c8513ea24ab8fd0577034804a967248096") },
        .{ &[_]u8 { 0x00, 0x00, 'd' }, &utils.parseHash("b6dc933311bc2357cc5fc636a4dbe41a01b7a33b583d043a7f870f3440697e27") },
        .{ &[_]u8 { 0x00, 0x00, 'e' }, &utils.parseHash("1ad25d0002690dc02e2708a297d8c9df1f160d376f663309cc261c7c921367e7") },

        .{ &[_]u8 { 0x00, 0x01      }, &utils.parseHash("1ca9140a5b30b5576694b7d45ce1af298d858a58dfa2376302f540ee75a89348") },
        .{ &[_]u8 { 0x00, 0x01, 'd' }, &utils.parseHash("7a4861380d8de83d51f59d9cf42e47f6b955b90302f0328c1ec27cb349596f07") },

        .{ &[_]u8 { 0x00, 0x02,     }, &utils.parseHash("b8d64c1df3806e394ba9b56a74b6b10eb90e5c0979a3564b8e9efec9791c68cb") },
        .{ &[_]u8 { 0x00, 0x02, 'd' }, &utils.parseHash("b008970bf72be98f3614caccbbf30baccc64273c197c539a20c1cd4b7cac8b05") },

        .{ &[_]u8 { 0x00, 0x03,     }, &utils.parseHash("87913c5185f2175261903739964148c744b183c0991ae003ed6289d0541e3ad5") },
        .{ &[_]u8 { 0x00, 0x03, 'd' }, &utils.parseHash("5916a54da06b4a95b841f5da524e871a014cd1bf72e6ed400bc35a3754294c05") },

        .{ &[_]u8 { 0x00, 0x04,     }, &utils.parseHash("b097bc997119c6a0aa2fd760163ecdf184f4c490b2e86476ab15e2d80fca1146") },
        .{ &[_]u8 { 0x00, 0x04, 'd' }, &utils.parseHash("3e8a33e514301e57922b4a4c5737e28dd65db1d2b4f49da619e772ab8e4a714d") },
        
        .{ &[_]u8 { 0x00, 0x05,     }, &utils.parseHash("ac62313cd354bb52f897110b9ca4c840532e09eced40f59879c06689c5588f30") },
        .{ &[_]u8 { 0xFF, 0xFF      }, &[_]u8 { 0x01, 0x04, 0x00, 0x00, 0x05 } },
    };

    try testEntryList(&leaves, &entries, .{ .degree = 4 });
}

test "Builder(10)" {
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

    try testEntryList(&leaves, &entries, .{ .degree = 4 });
}