const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const utils = @import("utils.zig");

const DATABASE_VERSION = 0x01;

fn getFanoutDegree(comptime Q: u32) [4]u8 {
    var value: [4]u8 = .{ 0, 0, 0, 0 };
    std.mem.writeIntBig(u32, &value, Q);
    return value;
}

pub fn Header(comptime K: u8, comptime Q: u32) type {
    return struct {
        pub const HEADER_KEY = [1]u8{0xFF};
        pub const ANCHOR_KEY = [1]u8{0x00};

        const header = [_]u8{ 'o', 'k', 'r', 'a', DATABASE_VERSION, K } ++ getFanoutDegree(Q);

        pub fn initialize(env: lmdb.Environment, dbi: ?[*:0]const u8) !void {
            const txn = try lmdb.Transaction.open(env, .{ .read_only = false, .dbi = dbi });
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
                } else {
                    return error.InvalidDatabase;
                }
            } else {
                return error.InvalidDatabase;
            }
        }
    };
}
