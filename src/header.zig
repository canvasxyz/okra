const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const utils = @import("utils.zig");

fn getFanoutDegree(comptime Q: u32) [4]u8 {
    var value: [4]u8 = .{ 0, 0, 0, 0 };
    std.mem.writeIntBig(u32, &value, Q);
    return value;
}

pub fn Header(comptime K: u8, comptime Q: u32) type {
    return struct {
        pub const ANCHOR_KEY = [1]u8{0x00};
        pub const METADATA_KEY = [1]u8{0xff};

        pub const DATABASE_VERSION = 0x01;

        const header = [_]u8{ 'o', 'k', 'r', 'a', DATABASE_VERSION, K } ++ getFanoutDegree(Q);

        pub fn initialize(txn: lmdb.Transaction, dbi: lmdb.Transaction.DBI) !void {
            if (try txn.get(dbi, &METADATA_KEY)) |value| {
                if (std.mem.eql(u8, value, &header)) {
                    return;
                } else {
                    return error.InvalidDatabase6;
                }
            }

            write(txn, dbi) catch |err| {
                switch (err) {
                    error.ACCES => {},
                    else => {
                        return err;
                    },
                }
            };
        }

        pub fn write(txn: lmdb.Transaction, dbi: lmdb.Transaction.DBI) !void {
            var anchor_hash: [K]u8 = undefined;
            Blake3.hash(&[0]u8{}, &anchor_hash, .{});
            try txn.set(dbi, &ANCHOR_KEY, &anchor_hash);
            try txn.set(dbi, &METADATA_KEY, &header);
        }

        pub fn validate(txn: lmdb.Transaction, dbi: lmdb.Transaction.DBI) !void {
            if (try txn.get(dbi, &METADATA_KEY)) |value| {
                if (std.mem.eql(u8, value, &header)) {
                    return;
                } else {
                    return error.InvalidDatabase7;
                }
            } else {
                return error.InvalidDatabase8;
            }
        }
    };
}
