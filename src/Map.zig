const std = @import("std");
const lmdb = @import("lmdb");

const Error = @import("error.zig").Error;
const Entry = @import("Entry.zig");
const Tree = @import("./Tree.zig").Tree;

pub fn Map(comptime K: u8, comptime Q: u32) type {
    return struct {
        pub const Options = struct {
            log: ?std.fs.File.Writer = null,
        };

        const Self = @This();

        tree: Tree(K, Q),

        pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, options: Options) Error!Self {
            const tree = try Tree(K, Q).init(allocator, db, .{ .log = options.log });
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
            try self.tree.delete(key);
        }
    };
}
