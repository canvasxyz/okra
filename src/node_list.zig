const std = @import("std");
const allocator = std.heap.c_allocator;

pub fn NodeList(comptime K: u8, comptime Q: u32) type {
    const Cursor = @import("cursor.zig").Cursor(K, Q);
    const Node = @import("node.zig").Node(K, Q);

    return struct {
        const Self = @This();

        nodes: std.ArrayList(Node),

        pub fn init(cursor: *Cursor, level: u8, key: ?[]const u8, limit: ?[]const u8) !Self {
            var nodes = std.ArrayList(Node).init(allocator);

            const first_child = try cursor.goToNode(level - 1, key);
            try nodes.append(.{
                .level = level - 1,
                .key = try createKey(first_child.key),
                .hash = try createHash(first_child.hash),
                .value = try createKey(first_child.value),
            });

            while (try cursor.goToNext()) |next_child| {
                if (limit) |limit_key|
                    if (next_child.key) |next_child_key|
                        if (!std.mem.lessThan(u8, next_child_key, limit_key))
                            break;

                try nodes.append(.{
                    .level = level - 1,
                    .key = try createKey(next_child.key),
                    .hash = try createHash(next_child.hash),
                    .value = try createKey(next_child.value),
                });
            }

            return Self{ .nodes = nodes };
        }

        pub fn deinit(self: Self) void {
            for (self.nodes.items) |node| {
                allocator.free(node.hash);
                if (node.key) |key| {
                    allocator.free(key);
                }
            }

            self.nodes.deinit();
        }

        pub fn getLimit(self: Self, index: usize, limit: ?[]const u8) ?[]const u8 {
            if (index + 1 < self.nodes.items.len) {
                return self.nodes.items[index + 1].key;
            } else {
                return limit;
            }
        }

        fn createKey(key: ?[]const u8) !?[]const u8 {
            if (key) |bytes| {
                const result = try allocator.alloc(u8, bytes.len);
                std.mem.copy(u8, result, bytes);
                return result;
            } else {
                return null;
            }
        }

        fn createHash(hash: *const [K]u8) !*const [K]u8 {
            const result = try allocator.alloc(u8, K);
            std.mem.copy(u8, result, hash);
            return result[0..K];
        }
    };
}
