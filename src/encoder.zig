const std = @import("std");

const Entry = @import("Entry.zig");

pub fn Encoder(comptime K: u8, comptime Q: u32) type {
    const Node = @import("node.zig").Node(K, Q);

    return struct {
        const Self = @This();

        key_buffer: std.ArrayList(u8),
        value_buffer: std.ArrayList(u8),

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

        pub fn encode(self: *Self, node: Node) std.mem.Allocator.Error!Entry {
            const key = try self.encodeKey(node.level, node.key);
            const value = try self.encodeValue(node.hash, node.value);
            return .{ .key = key, .value = value };
        }

        pub fn encodeKey(self: *Self, level: u8, key: ?[]const u8) std.mem.Allocator.Error![]u8 {
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

        pub fn encodeValue(self: *Self, hash: *const [K]u8, value: ?[]const u8) std.mem.Allocator.Error![]u8 {
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

        pub fn decode(self: *Self, key: []const u8, value: []const u8) std.mem.Allocator.Error!Node {
            try self.key_buffer.resize(key.len);
            @memcpy(self.key_buffer.items, key);

            try self.value_buffer.resize(value.len);
            @memcpy(self.value_buffer.items, value);

            return Node.parse(self.key_buffer.items, self.value_buffer.items);
        }

        pub fn createLeaf(self: *Self, key: []const u8, value: []const u8) std.mem.Allocator.Error!Node {
            var hash: [K]u8 = undefined;
            Entry.hash(key, value, &hash);

            return try self.copy(.{
                .level = 0,
                .key = key,
                .hash = &hash,
                .value = value,
            });
        }

        pub fn copyKey(self: *Self, level: u8, key: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
            if (key) |bytes| {
                try self.key_buffer.resize(1 + bytes.len);
                self.key_buffer.items[0] = level;
                @memcpy(self.key_buffer.items[1..], bytes);
                return self.key_buffer.items[1..];
            } else {
                return null;
            }
        }

        pub fn copy(self: *Self, node: Node) std.mem.Allocator.Error!Node {
            const entry = try self.encode(node);
            return try Node.parse(entry);
        }
    };
}
