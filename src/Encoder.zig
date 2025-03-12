const std = @import("std");

const Entry = @import("Entry.zig");

const nil: [0]u8 = .{};

pub fn Encoder(comptime K: u8, comptime Q: u32) type {
    const Node = @import("Node.zig").Node(K, Q);

    return struct {
        const Self = @This();

        buffer: std.ArrayList(u8),

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .buffer = std.ArrayList(u8).init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        pub fn encode(self: *Self, node: Node) std.mem.Allocator.Error!Entry {
            const key = node.key orelse &nil;
            const value = node.value orelse &nil;

            try self.buffer.resize(1 + key.len + K + value.len);

            const entry_key = self.buffer.items[0 .. 1 + key.len];
            const entry_value = self.buffer.items[1 + key.len ..];

            entry_key[0] = node.level;
            @memcpy(entry_key[1..], key);
            @memcpy(entry_value[0..K], node.hash);
            @memcpy(entry_value[K..], value);

            return .{ .key = entry_key, .value = entry_value };
        }

        pub fn encodeKey(self: *Self, level: u8, key: ?[]const u8) std.mem.Allocator.Error![]const u8 {
            if (key) |bytes| {
                try self.buffer.resize(1 + bytes.len);
                self.buffer.items[0] = level;
                @memcpy(self.buffer.items[1..], bytes);
            } else {
                try self.buffer.resize(1);
                self.buffer.items[0] = level;
            }

            return self.buffer.items;
        }
    };
}
