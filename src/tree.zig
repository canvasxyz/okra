const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;
const Blake3 = std.crypto.hash.Blake3;

const lmdb = @import("lmdb");

const Error = @import("error.zig").Error;
const Effects = @import("Effects.zig");
const Entry = @import("Entry.zig");
const Key = @import("Key.zig");

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

        arena: std.heap.ArenaAllocator,
        db: lmdb.Database,
        cursor: Cursor,
        encoder: Encoder,
        logger: ?std.fs.File.Writer,
        effects: ?*Effects,

        pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, options: Options) Error!Self {
            try Header.initialize(db);

            const cursor = try Cursor.init(allocator, db);

            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .db = db,
                .cursor = cursor,
                .encoder = Encoder.init(allocator),
                .logger = options.log,
                .effects = options.effects,
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.cursor.deinit();
            self.encoder.deinit();
        }

        pub fn get(self: *Self, key: []const u8) Error!?[]const u8 {
            const node = try self.getNode(0, key) orelse return null;
            return node.value orelse error.InvalidDatabase;
        }

        pub fn set(self: *Self, key: []const u8, value: []const u8) Error!void {
            const allocator = self.arena.allocator();
            defer assert(self.arena.reset(.free_all));

            if (self.effects) |effects| effects.reset();

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
                        try self.updateNode(allocator, 1, key);
                    } else {
                        try self.setNode(new_leaf);
                        try self.deleteNode(1, key);

                        const new_parent = try self.getParent(allocator, 0, key);
                        defer if (new_parent) |bytes| allocator.free(bytes);

                        try self.updateNode(allocator, 1, new_parent);
                    }
                } else {
                    try self.dispatch(allocator, new_leaf);
                }
            } else {
                try self.dispatch(allocator, new_leaf);
            }
        }

        pub fn delete(self: *Self, key: []const u8) Error!void {
            const allocator = self.arena.allocator();
            defer assert(self.arena.reset(.free_all));

            if (self.effects) |effects| effects.reset();

            if (try self.getNode(0, key)) |_| {
                try self.deleteNode(0, key);

                const new_parent = try self.getParent(allocator, 0, key);
                defer if (new_parent) |bytes| allocator.free(bytes);

                try self.updateNode(allocator, 1, new_parent);
            }
        }

        pub fn getRoot(self: *Self) !Node {
            return try self.cursor.goToRoot();
        }

        pub fn getNode(self: *Self, level: u8, key: ?[]const u8) Error!?Node {
            const entry_key = try self.encoder.encodeKey(level, key);
            if (try self.db.get(entry_key)) |entry_value| {
                return try Node.parse(entry_key, entry_value);
            } else {
                return null;
            }
        }

        inline fn setNode(self: *Self, node: Node) Error!void {
            const entry = try self.encoder.encode(node);
            try self.db.set(entry.key, entry.value);
        }

        fn dispatch(self: *Self, allocator: std.mem.Allocator, node: Node) Error!void {
            const old_parent = try self.getParent(allocator, node.level, node.key);
            defer if (old_parent) |bytes| allocator.free(bytes);

            try self.setNode(node);

            if (node.isBoundary()) {
                try self.createNode(node.level + 1, node.key);
            }

            try self.updateNode(allocator, node.level + 1, old_parent);
        }

        fn updateNode(self: *Self, allocator: std.mem.Allocator, level: u8, key: ?[]const u8) Error!void {
            var hash: [K]u8 = undefined;
            try self.getHash(level, key, &hash);

            const new_node = Node{ .level = level, .key = key, .hash = &hash };
            if (new_node.isAnchor()) {
                try self.setNode(new_node);
                try self.cursor.goToNode(level, key);
                if (try self.cursor.goToNext()) |_| {
                    try self.updateNode(allocator, level + 1, null);
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
                    try self.updateNode(allocator, level + 1, key);
                } else {
                    try self.deleteNode(level + 1, key);
                    try self.setNode(new_node);

                    const new_parent = try self.getParent(allocator, level, key);
                    defer if (new_parent) |bytes| allocator.free(bytes);

                    try self.updateNode(allocator, level + 1, new_parent);
                }
            } else {
                try self.dispatch(allocator, new_node);
            }
        }

        fn deleteNode(self: *Self, level: u8, key: ?[]const u8) Error!void {
            const entry_key = try self.encoder.encodeKey(level, key);
            if (try self.db.get(entry_key)) |_| {
                try self.db.delete(entry_key);
                if (self.effects) |effects| effects.delete += 1;

                try self.deleteNode(level + 1, key);
            }
        }

        fn createNode(self: *Self, level: u8, key: ?[]const u8) !void {
            assert(level > 0);

            var hash: [K]u8 = undefined;
            var node = Node{ .level = level, .key = key, .hash = &hash };
            while (node.level == level or node.isBoundary()) : (node.level += 1) {
                try self.getHash(node.level, key, &hash);
                try self.setNode(node);
                if (self.effects) |effects| effects.create += 1;
            }
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

        fn getParent(self: *Self, allocator: std.mem.Allocator, level: u8, key: ?[]const u8) Error!?[]const u8 {
            if (key == null) {
                return error.InvalidDatabase;
            }

            if (try self.cursor.seek(level, key)) |next| {
                if (Key.equal(next.key, key) and next.isBoundary()) {
                    return try copyKey(allocator, next.key);
                }
            }

            while (try self.cursor.goToPrevious()) |previous| {
                if (previous.isAnchor()) {
                    return null;
                } else if (previous.isBoundary()) {
                    return try copyKey(allocator, previous.key);
                }
            }

            return error.InvalidDatabase;
        }

        inline fn copyKey(allocator: std.mem.Allocator, key: ?[]const u8) !?[]const u8 {
            if (key) |bytes| {
                const result = try allocator.alloc(u8, bytes.len);
                @memcpy(result, bytes);
                return result;
            } else {
                return null;
            }
        }

        inline fn log(self: Self, comptime format: []const u8, args: anytype) std.fs.File.WriteError!void {
            if (self.logger) |writer| {
                try writer.print(format, args);
            }
        }
    };
}
