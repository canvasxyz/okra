const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const Logger = @import("logger.zig").Logger;
const utils = @import("utils.zig");

/// Builder is naive bottom-up tree builder used for unit testing.
/// It's is also used in the `okra rebuild` cli command.
/// Create a builder with Builder.open(allocator, env, options),
/// insert as many leaves as you want, and then commit.
pub fn Builder(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);

    return struct {
        const Self = @This();
        pub const Options = struct { log: ?std.fs.File.Writer = null };

        txn: lmdb.Transaction,
        cursor: lmdb.Cursor,
        key_buffer: std.ArrayList(u8),
        value_buffer: std.ArrayList(u8),
        hash_buffer: [K]u8 = undefined,
        logger: Logger,

        pub fn open(allocator: std.mem.Allocator, env: lmdb.Environment, options: Options) !Self {
            var builder: Self = undefined;
            try builder.init(allocator, env, options);
            return builder;
        }

        pub fn init(self: *Self, allocator: std.mem.Allocator, env: lmdb.Environment, options: Options) !void {
            self.logger = Logger.init(allocator, options.log);
            self.txn = try lmdb.Transaction.open(env, .{ .read_only = false });
            errdefer self.txn.abort();

            try Header.write(self.txn);

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
            try self.setNode(key, value);
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

        fn setNode(self: *Self, key: []const u8, value: []const u8) !void {
            try self.setKey(0, key);
            try self.value_buffer.resize(K + value.len);
            utils.hashEntry(key, value, self.value_buffer.items[0..K]);
            std.mem.copy(u8, self.value_buffer.items[K..], value);
        }

        fn log(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.logger.print(format, args);
        }

        fn isSplit(value: *const [K]u8) bool {
            const limit: comptime_int = (1 << 32) / @intCast(u33, Q);
            return std.mem.readIntBig(u32, value[0..4]) < limit;
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
