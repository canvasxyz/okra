const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("lmdb");

fn getFanoutDegree(comptime Q: u32) [4]u8 {
    var value: [4]u8 = .{ 0, 0, 0, 0 };
    std.mem.writeInt(u32, &value, Q, .big);
    return value;
}

pub fn Header(comptime K: u8, comptime Q: u32) type {
    return struct {
        pub const ANCHOR_KEY = [1]u8{0x00};
        pub const METADATA_KEY = [1]u8{0xff};

        pub const DATABASE_VERSION = 0x02;

        const header = [_]u8{ 'o', 'k', 'r', 'a', DATABASE_VERSION, K } ++ getFanoutDegree(Q);

        pub fn initialize(db: lmdb.Database) !void {
            if (try db.get(&METADATA_KEY)) |value| {
                if (std.mem.eql(u8, value, &header)) {
                    return;
                } else {
                    return error.InvalidDatabase;
                }
            }

            write(db) catch |err| {
                switch (err) {
                    error.ACCES => {},
                    else => {
                        return err;
                    },
                }
            };
        }

        pub fn write(db: lmdb.Database) !void {
            var anchor_hash: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(&[0]u8{}, &anchor_hash, .{});
            try db.set(&ANCHOR_KEY, anchor_hash[0..K]);
            try db.set(&METADATA_KEY, &header);
        }

        pub fn validate(db: lmdb.Database) !void {
            if (try db.get(&METADATA_KEY)) |value| {
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
