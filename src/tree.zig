const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const Error = @import("error.zig").Error;
const Effects = @import("Effects.zig");
const Logger = @import("Logger.zig");
const BufferPool = @import("BufferPool.zig");
const Entry = @import("Entry.zig");
const Key = @import("Key.zig");

const nil = [0]u8{};

pub fn Tree(comptime K: u8, comptime Q: u32) type {
    const Header = @import("header.zig").Header(K, Q);
    const Node = @import("node.zig").Node(K, Q);
    const Cursor = @import("cursor.zig").Cursor(K, Q);
    const Encoder = @import("encoder.zig").Encoder(K, Q);

    return struct {
        const Self = @This();

        pub const Options = struct {
            log: ?std.fs.File.Writer = null,
            effects: ?*Effects = null,
        };

        allocator: std.mem.Allocator,
        db: lmdb.Database,
        cursor: Cursor,
        encoder: Encoder,
        pool: BufferPool,
        logger: ?std.fs.File.Writer,
        effects: ?*Effects,

        pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, options: Options) Error!Self {
            try Header.initialize(db);

            const cursor = try Cursor.init(allocator, db);

            return .{
                .allocator = allocator,
                .db = db,
                .cursor = cursor,
                .encoder = Encoder.init(allocator),
                .pool = BufferPool.init(allocator),
                .logger = options.log,
                .effects = options.effects,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cursor.deinit();
            self.encoder.deinit();
            self.pool.deinit();
        }

        pub fn get(self: *Self, key: []const u8) Error!?[]const u8 {
            const node = try self.getNode(0, key) orelse return null;
            return node.value orelse error.InvalidDatabase;
        }

        pub fn set(self: *Self, key: []const u8, value: []const u8) Error!void {
            if (self.effects) |effects| effects.reset();

            const root = try self.cursor.goToRoot();
            try self.pool.resize(root.level + 1);

            var hash: [K]u8 = undefined;
            Entry.hash(key, value, &hash);
            const new_leaf = Node{ .level = 0, .key = key, .hash = &hash, .value = value };

            if (try self.getNode(0, key)) |old_leaf| {
                const old_value = old_leaf.value orelse return error.InvalidDatabase;
                if (std.mem.eql(u8, old_value, value)) {
                    return;
                }

                if (old_leaf.isBoundary()) {
                    if (new_leaf.isBoundary()) {
                        try self.setNode(new_leaf);
                        try self.updateNode(1, key);
                    } else {
                        try self.setNode(new_leaf);
                        try self.deleteNode(1, key);

                        const new_parent = try self.getParent(0, key);

                        try self.updateNode(1, new_parent);
                    }
                } else {
                    try self.dispatch(new_leaf);
                }
            } else {
                try self.dispatch(new_leaf);
            }

            // try self.log("------------------------\n", .{});
        }

        pub fn delete(self: *Self, key: []const u8) Error!void {
            try self.log("------------------------\n", .{});
            try self.log("delete({s})\n", .{hex(key)});
            try self.print();

            if (self.effects) |effects| effects.reset();

            const root = try self.cursor.goToRoot();
            try self.pool.resize(root.level + 1);

            if (try self.getNode(0, key)) |_| {
                try self.deleteNode(0, key);

                const new_parent = try self.getParent(0, key);

                try self.updateNode(1, new_parent);
            }

            try self.log("------------------------\n", .{});
        }

        fn dispatch(self: *Self, node: Node) Error!void {
            const old_parent = try self.getParent(node.level, node.key);

            try self.setNode(node);

            if (node.isBoundary()) {
                try self.createNode(node.level + 1, node.key);
            }

            try self.updateNode(node.level + 1, old_parent);
        }

        fn updateNode(self: *Self, level: u8, key: ?[]const u8) Error!void {
            var hash: [K]u8 = undefined;
            try self.getHash(level, key, &hash);

            const new_node = Node{ .level = level, .key = key, .hash = &hash };
            if (new_node.isAnchor()) {
                try self.setNode(new_node);
                try self.cursor.goToNode(level, key);
                if (try self.cursor.goToNext()) |_| {
                    try self.updateNode(level + 1, null);
                } else {
                    try self.deleteNode(level + 1, null);
                }

                return;
            }

            if (self.effects) |effects| effects.update += 1;

            const old_node = try self.getNode(level, key) orelse return error.NotFound;
            if (old_node.isBoundary()) {
                if (new_node.isBoundary()) {
                    try self.setNode(new_node);
                    try self.updateNode(level + 1, key);
                } else {
                    try self.deleteNode(level + 1, key);
                    try self.setNode(new_node);

                    const new_parent = try self.getParent(level, key);

                    try self.updateNode(level + 1, new_parent);
                }
            } else {
                try self.dispatch(new_node);
            }
        }

        fn deleteNode(self: *Self, level: u8, key: ?[]const u8) Error!void {
            const entry_key = try self.encoder.encodeKey(level, key);
            while (try self.db.get(entry_key)) |_| {
                try self.db.delete(entry_key);
                if (self.effects) |effects| effects.delete += 1;

                entry_key[0] += 1;
            }
        }

        fn createNode(self: *Self, level: u8, key: ?[]const u8) !void {
            assert(level > 0);

            var hash: [K]u8 = undefined;
            var l = level;
            while (true) : (l += 1) {
                try self.getHash(l, key, &hash);

                const entry_key = try self.encoder.encodeKey(l, key);
                try self.db.set(entry_key, &hash);
                if (self.effects) |effects| effects.create += 1;

                if (isBoundary(&hash)) {
                    continue;
                } else {
                    break;
                }
            }
        }

        fn getNode(self: *Self, level: u8, key: ?[]const u8) Error!?Node {
            const entry_key = try self.encoder.encodeKey(level, key);
            if (try self.db.get(entry_key)) |entry_value| {
                return try Node.parse(entry_key, entry_value);
            } else {
                return null;
            }
        }

        fn setNode(self: *Self, node: Node) Error!void {
            const entry = try self.encoder.encode(node);
            try self.db.set(entry.key, entry.value);
        }

        fn getParent(self: *Self, level: u8, key: ?[]const u8) Error!?[]const u8 {
            assert(key != null);
            if (key == null) {
                return null;
            }

            if (try self.cursor.seek(level, key)) |next| {
                if (Key.equal(next.key, key) and next.isBoundary()) {
                    return try self.pool.copy(level, next.key.?);
                }
            }

            while (try self.cursor.goToPrevious()) |previous| {
                if (previous.isAnchor()) {
                    return null;
                } else if (previous.isBoundary()) {
                    return try self.pool.copy(level, previous.key.?);
                }
            }

            return error.InvalidDatabase;
        }

        fn getHash(self: *Self, level: u8, key: ?[]const u8, hash: *[K]u8) Error!void {
            var digest = std.crypto.hash.Blake3.init(.{});

            try self.cursor.goToNode(level - 1, key);

            const first_node = try self.cursor.getCurrentNode();
            assert(first_node.isAnchor() or first_node.isBoundary());

            digest.update(first_node.hash);

            while (try self.cursor.goToNext()) |next| {
                if (next.isBoundary()) {
                    break;
                } else {
                    digest.update(next.hash);
                }
            }

            digest.final(hash);
        }

        fn isAnchor(key: []const u8) bool {
            return key.len == 1;
        }

        fn isBoundary(hash: *const [K]u8) bool {
            const limit: comptime_int = (1 << 32) / @as(u33, @intCast(Q));
            return std.mem.readInt(u32, hash[0..4], .big) < limit;
        }

        fn log(self: Self, comptime format: []const u8, args: anytype) std.fs.File.WriteError!void {
            if (self.logger) |writer| {
                try writer.print(format, args);
            }
        }

        fn print(self: Self) !void {
            if (self.logger == null) {
                return;
            }

            const cursor = try self.db.cursor();
            defer cursor.deinit();

            try self.log("------------\n", .{});

            if (try cursor.goToFirst()) |key| {
                const value = try cursor.getCurrentValue();
                try self.log("{s}\t{s}\n", .{ hex(key), hex(value) });
            }

            while (try cursor.goToNext()) |key| {
                const value = try cursor.getCurrentValue();
                if (std.mem.eql(u8, key, &Header.METADATA_KEY)) {
                    try self.log("{s}\t{s}\n", .{ hex(key), hex(value) });
                } else {
                    try self.log("{s}\t{s}\t[{any}]\n", .{ hex(key), hex(value), isBoundary(value[0..K]) });
                }
            }

            try self.log("------------\n", .{});
        }
    };
}
