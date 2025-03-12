const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const Entry = @import("Entry.zig");

/// Builder is naive bottom-up tree builder used for unit testing.
/// It's is also used in the `okra rebuild` cli command.
/// Create a builder with Builder.open(allocator, env, options),
/// insert as many leaves as you want, and then commit.
pub fn Builder(comptime K: u8, comptime Q: u32) type {
    const Header = @import("Header.zig").Header(K, Q);

    return struct {
        const Self = @This();
        pub const Options = struct { log: ?std.fs.File.Writer = null };

        db: lmdb.Database,
        hash_buffer: [K]u8 = undefined,
        key_buffer: std.ArrayList(u8),
        value_buffer: std.ArrayList(u8),
        logger: ?std.fs.File.Writer,

        pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, options: Options) !Self {
            try Header.write(db);

            return .{
                .db = db,
                .key_buffer = std.ArrayList(u8).init(allocator),
                .value_buffer = std.ArrayList(u8).init(allocator),
                .logger = options.log,
            };
        }

        pub fn deinit(self: *Self) void {
            self.key_buffer.deinit();
            self.value_buffer.deinit();
        }

        pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
            try self.setNode(key, value);
            try self.db.set(self.key_buffer.items, self.value_buffer.items);
        }

        pub fn delete(self: *Self, key: []const u8) !void {
            try self.setKey(0, key);
            try self.db.delete(self.key_buffer.items);
        }

        pub fn build(self: *Self) !void {
            const cursor = try self.db.cursor();
            defer cursor.deinit();

            try cursor.goToKey(&[_]u8{0});

            var level: u8 = 0;
            while (true) : (level += 1) {
                const count = try self.buildLevel(cursor, level);
                if (count == 0) {
                    break;
                } else if (count == 1) {
                    break;
                }
            }
        }

        fn buildLevel(self: *Self, cursor: lmdb.Cursor, level: u8) !usize {
            try self.log("LEVEL {d} -------------", .{level});
            const first_key = try cursor.getCurrentKey();
            assert(first_key.len == 1);
            assert(first_key[0] == level);

            try self.log("new digest staring with key null", .{});
            var digest = Blake3.init(.{});

            {
                const value = try cursor.getCurrentValue();
                const hash = try getNodeHash(value);
                try self.log("digest.update({s})", .{hex(hash)});
                digest.update(hash);
            }

            try self.setKey(level + 1, &[_]u8{});

            var parent_count: usize = 0;
            var child_count: usize = 0;

            while (try cursor.goToNext()) |next_key| {
                if (next_key[0] != level) break;

                const value = try cursor.getCurrentValue();
                const hash = try getNodeHash(value);
                try self.log("key: {s}, hash: {s}, is_boundary: {any}", .{ hex(next_key), hex(hash), isBoundary(hash) });
                if (isBoundary(hash)) {
                    digest.final(&self.hash_buffer);
                    try self.log("digest.final() => {s}", .{hex(&self.hash_buffer)});
                    parent_count += 1;
                    try self.log("setting parent {s} -> {s}", .{ hex(self.key_buffer.items), hex(&self.hash_buffer) });
                    try self.db.set(self.key_buffer.items, &self.hash_buffer);

                    const key = try cursor.getCurrentKey();
                    try self.setKey(level + 1, key[1..]);

                    try self.log("new digest staring with key {s}", .{hex(next_key)});
                    digest = Blake3.init(.{});
                    const next_value = try cursor.getCurrentValue();
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
            try self.db.set(self.key_buffer.items, &self.hash_buffer);
            return parent_count + 1;
        }

        fn setKey(self: *Self, level: u8, key: []const u8) !void {
            try self.key_buffer.resize(1 + key.len);
            self.key_buffer.items[0] = level;
            @memcpy(self.key_buffer.items[1..], key);
        }

        fn setNode(self: *Self, key: []const u8, value: []const u8) !void {
            try self.setKey(0, key);
            try self.value_buffer.resize(K + value.len);
            Entry.hash(key, value, self.value_buffer.items[0..K]);
            @memcpy(self.value_buffer.items[K..], value);
        }

        inline fn log(self: Self, comptime format: []const u8, args: anytype) std.fs.File.WriteError!void {
            if (self.logger) |writer| {
                try writer.print(format, args);
            }
        }

        inline fn isBoundary(value: *const [K]u8) bool {
            const limit: comptime_int = (1 << 32) / @as(u33, @intCast(Q));
            return std.mem.readInt(u32, value[0..4], .big) < limit;
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
