const std = @import("std");
const lmdb = @import("lmdb");

const Error = @import("error.zig").Error;
const Entry = @import("Entry.zig");

pub fn Store(comptime K: u8, comptime Q: u32) type {
    const Node = @import("./Node.zig").Node(K, Q);
    const Tree = @import("./Tree.zig").Tree(K, Q);

    return struct {
        pub const Options = struct {
            log: ?std.fs.File.Writer = null,
        };

        const Self = @This();

        tree: Tree,

        pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, options: Options) Error!Self {
            const tree = try Tree.init(allocator, db, .Store, .{ .log = options.log });
            return .{ .tree = tree };
        }

        pub inline fn deinit(self: *Self) void {
            self.tree.deinit();
        }

        pub inline fn get(self: *Self, key: []const u8) Error!?[]const u8 {
            const leaf = try self.tree.getLeaf(key) orelse return null;
            return leaf.value orelse return error.InvalidDatabase;
        }

        pub inline fn set(self: *Self, key: []const u8, value: []const u8) Error!void {
            var hash: [K]u8 = undefined;
            Entry.hash(key, value, &hash);

            try self.tree.setLeaf(.{
                .level = 0,
                .key = key,
                .hash = &hash,
                .value = value,
            });
        }

        pub inline fn delete(self: *Self, key: []const u8) Error!void {
            try self.tree.deleteLeaf(key);
        }

        pub inline fn getRoot(self: *Self) !Node {
            return try self.tree.getRoot();
        }

        pub inline fn getNode(self: *Self, level: u8, key: ?[]const u8) !?Node {
            return try self.tree.getNode(level, key);
        }
    };
}
