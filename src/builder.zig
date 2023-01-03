const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const Header = @import("header.zig").Header;
const Logger = @import("logger.zig").Logger;
const print = @import("print.zig");
const utils = @import("utils.zig");

pub const Options = struct { log: ?std.fs.File.Writer = null };

/// A Builder is naive bottom-up tree builder used to construct large trees
/// at once and for reference when unit testing SkipList.
/// Create a builder with Builder.init(env, options), insert as many leaves
/// as you want using .set(key, value), and then call .commit().
/// Builder is also used in the rebuild cli command.
pub fn Builder(comptime Q: u8, comptime K: u8) type {
    return struct {
        txn: lmdb.Transaction,
        cursor: lmdb.Cursor,
        key_buffer: std.ArrayList(u8),
        value_buffer: std.ArrayList(u8),
        hash_buffer: [K]u8 = undefined,
        logger: Logger,

        const Self = @This();

        pub fn open(allocator: std.mem.Allocator, env: lmdb.Environment, options: Options) !Self {
            var builder: Self = undefined;
            try builder.init(allocator, env, options);
            return builder;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, env: lmdb.Environment, options: Options) !void {
            self.logger = Logger.init(allocator, options.log);
            self.txn = try lmdb.Transaction.open(env, .{ .read_only = false });
            errdefer self.txn.abort();

            try Header(Q, K).write(self.txn);

            self.cursor = try lmdb.Cursor.open(self.txn);
            self.key_buffer = std.ArrayList(u8).init(allocator);
            self.value_buffer = std.ArrayList(u8).init(allocator);
        }

        pub fn abort(self: *Self) void {
            self.key_buffer.deinit();
            self.value_buffer.deinit();
            self.txn.abort();
        }

        pub fn commit(self: *Self) !void {
            defer self.key_buffer.deinit();
            defer self.value_buffer.deinit();
            errdefer self.txn.abort();

            try self.cursor.goToKey(&[_]u8{0});

            var level: u8 = 0;
            while (true) : (level += 1) {
                const count = try self.buildLevel(level);
                if (count == 0) {
                    break;
                } else if (count == 1) {
                    break;
                }
            }

            try self.txn.commit();
        }

        pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
            try self.setKey(0, key);
            try self.setValue(value);
            try self.txn.set(self.key_buffer.items, self.value_buffer.items);
        }

        pub fn delete(self: *Self, key: []const u8) !void {
            try self.setKey(0, key);
            try self.txn.delete(self.key_buffer.items);
        }

        fn buildLevel(self: *Self, level: u8) !usize {
            try self.log("LEVEL {d} -------------", .{level});
            const first_key = try self.cursor.getCurrentKey();
            assert(first_key.len == 1);
            assert(first_key[0] == level);

            try self.log("new digest staring with key null", .{});
            var digest = Blake3.init(.{});

            {
                const value = try self.cursor.getCurrentValue();
                const hash = try getNodeHash(value);
                try self.log("digest.update({s})", .{hex(hash)});
                digest.update(hash);
            }

            try self.setKey(level + 1, &[_]u8{});

            var parent_count: usize = 0;
            var child_count: usize = 0;

            while (try self.cursor.goToNext()) |next_key| {
                if (next_key[0] != level) break;

                const value = try self.cursor.getCurrentValue();
                const hash = try getNodeHash(value);
                try self.log("key: {s}, hash: {s}, is_split: {any}", .{ hex(next_key), hex(hash), isSplit(hash) });
                if (isSplit(hash)) {
                    digest.final(&self.hash_buffer);
                    try self.log("digest.final() => {s}", .{hex(&self.hash_buffer)});
                    parent_count += 1;
                    try self.log("setting parent {s} -> {s}", .{ hex(self.key_buffer.items), hex(&self.hash_buffer) });
                    try self.txn.set(self.key_buffer.items, &self.hash_buffer);

                    const key = try self.cursor.getCurrentKey();
                    try self.setKey(level + 1, key[1..]);

                    try self.log("new digest staring with key {s}", .{hex(next_key)});
                    digest = Blake3.init(.{});
                    const next_value = try self.cursor.getCurrentValue();
                    const next_hash = try getNodeHash(next_value);
                    try self.log("digest.update({s})", .{hex(next_hash)});
                    digest.update(next_hash);
                    child_count += 1;
                } else {
                    try self.log("digest.update({s})", .{hex(hash)});
                    digest.update(hash);
                    child_count += 1;
                }
            }

            if (child_count == 0) {
                return 0;
            }

            digest.final(&self.hash_buffer);
            try self.txn.set(self.key_buffer.items, &self.hash_buffer);
            return parent_count + 1;
        }

        fn setKey(self: *Self, level: u8, key: []const u8) !void {
            try self.key_buffer.resize(1 + key.len);
            self.key_buffer.items[0] = level;
            std.mem.copy(u8, self.key_buffer.items[1..], key);
        }

        fn setValue(self: *Self, value: []const u8) !void {
            try self.value_buffer.resize(K + value.len);
            Blake3.hash(value, self.value_buffer.items[0..K], .{});
            std.mem.copy(u8, self.value_buffer.items[K..], value);
        }

        fn log(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.logger.print(format, args);
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
    };
}

var path_buffer: [4096]u8 = undefined;

const Entry = [2][]const u8;

fn testEntryList(comptime Q: u8, comptime K: u8, leaves: []const Entry, entries: []const Entry, options: Options) !void {
    const allocator = std.heap.c_allocator;

    // const log = std.io.getStdErr().writer();
    // try log.print("\n", .{});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    var builder = try Builder(Q, K).open(allocator, env, options);

    for (leaves) |leaf| try builder.set(leaf[0], leaf[1]);

    try builder.commit();

    // try log.print("----------------------------------------------------------------\n", .{});
    // try print.printEntries(env, log);

    try lmdb.expectEqualEntries(env, entries);

    // try log.print("----------------------------------------------------------------\n", .{});
    // try printTree(allocator, env, log, .{ .compact = true });
}

fn l(comptime N: u8) [1]u8 {
    return [1]u8{N};
}

fn h(comptime value: *const [64]u8) [32]u8 {
    var buffer: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

test "Builder()" {
    const leaves = [_]Entry{};

    const entries = [_]Entry{
        // Blake3() = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
        .{ &l(0), &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },

        .{ &l(0xFF), &[_]u8{ 'o', 'k', 'r', 'a', 1, 4, 32 } },
    };

    try testEntryList(4, 32, &leaves, &entries, .{});
}

test "Builder(a, b, c)" {
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

    try testEntryList(4, 32, &leaves, &entries, .{});
}

test "Builder(a, b, c, d)" {
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

    try testEntryList(4, 32, &leaves, &entries, .{});
}

test "Builder(a, b, c, d, e)" {
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

    try testEntryList(4, 32, &leaves, &entries, .{});
}

test "Builder(a, c, d, e)" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    {
        var builder = try Builder(4, 32).open(allocator, env, .{});
        errdefer builder.abort();

        try builder.set("a", "foo");
        try builder.set("b", "bar");
        try builder.set("c", "baz");
        try builder.set("d", "wow");
        try builder.set("e", "aaa");

        try builder.delete("b");

        try builder.commit();
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

    try lmdb.expectEqualEntries(env, &entries);
}

test "Builder(10)" {
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

    try testEntryList(4, 32, &leaves, &entries, .{});
}
