const std = @import("std");

const Entry = @import("Entry.zig");

pub fn Encoder(comptime K: u8, comptime Q: u32) type {
    const Node = @import("node.zig").Node(K, Q);

    return struct {
        const Self = @This();

        value_buffer: std.ArrayList(u8),
        key_buffer: std.ArrayList(u8),

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .key_buffer = std.ArrayList(u8).init(allocator),
                .value_buffer = std.ArrayList(u8).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.key_buffer.deinit();
            self.value_buffer.deinit();
        }

        pub fn encode(self: *Self, node: Node) !Entry {
            const key = try self.encodeKey(node.level, node.key);
            const value = try self.encodeValue(node.hash, node.value);
            return .{ .key = key, .value = value };
        }

        pub fn encodeKey(self: *Self, level: u8, key: ?[]const u8) ![]const u8 {
            if (key) |bytes| {
                try self.key_buffer.resize(1 + bytes.len);
                self.key_buffer.items[0] = level;
                @memcpy(self.key_buffer.items[1..], bytes);
            } else {
                try self.key_buffer.resize(1);
                self.key_buffer.items[0] = level;
            }

            return self.key_buffer.items;
        }

        pub fn encodeValue(self: *Self, hash: *const [K]u8, value: ?[]const u8) ![]const u8 {
            if (value) |bytes| {
                try self.value_buffer.resize(K + bytes.len);
                @memcpy(self.value_buffer.items[0..K], hash);
                @memcpy(self.value_buffer.items[K..], bytes);
            } else {
                try self.value_buffer.resize(K);
                @memcpy(self.value_buffer.items, hash);
            }

            return self.value_buffer.items;
        }
    };
}
