const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const utils = @import("utils.zig");

pub fn Header(comptime Q: u8, comptime K: u8) type {
    return struct {
        pub const DATABASE_VERSION = 0x01;
        pub const HEADER_KEY = [1]u8{0xFF};
        pub const ANCHOR_KEY = [1]u8{0x00};

        const header = [_]u8{ 'o', 'k', 'r', 'a', DATABASE_VERSION, Q, K };

        pub fn initialize(env: lmdb.Environment) !void {
            const txn = try lmdb.Transaction.open(env, .{ .read_only = false });
            errdefer txn.abort();

            if (try txn.get(&HEADER_KEY)) |value| {
                if (std.mem.eql(u8, value, &header)) {
                    txn.abort();
                } else {
                    return error.InvalidDatabase;
                }
            } else {
                try write(txn);
                try txn.commit();
            }
        }

        pub fn write(txn: lmdb.Transaction) !void {
            var anchor_hash: [K]u8 = undefined;
            Blake3.hash(&[0]u8{}, &anchor_hash, .{});
            try txn.set(&ANCHOR_KEY, &anchor_hash);
            try txn.set(&HEADER_KEY, &header);
        }

        pub fn validate(txn: lmdb.Transaction) !void {
            if (try txn.get(&HEADER_KEY)) |value| {
                if (std.mem.eql(u8, value, &header)) {
                    return;
                }
            }

            return error.InvalidDatabase;
        }
    };
}

test "Header.initialize()" {
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    const env = try lmdb.Environment.open(path, .{});
    defer env.close();

    try Header(4, 32).initialize(env);

    try lmdb.expectEqualEntries(env, &.{
        .{ &[_]u8{0x00}, &utils.parseHash("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 4, 32 } },
    });
}
