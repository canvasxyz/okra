const std = @import("std");

// The buffer pool works on the observation that although the skip list needs to keep more
// than one heap-allocated key around at a time, it only needs one per level, and so a buffer pool
// can be indexed by the level.
pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)),

    pub fn init(allocator: std.mem.Allocator) BufferPool {
        return BufferPool{
            .allocator = allocator,
            .values = std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)){},
        };
    }

    pub fn deinit(self: *BufferPool) void {
        for (self.values.items) |*key| key.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }

    pub fn allocate(self: *BufferPool, size: usize) !void {
        if (self.values.items.len < size) {
            try self.values.appendNTimes(self.allocator, std.ArrayListUnmanaged(u8){}, size - self.values.items.len);
        }
    }

    pub fn set(self: *BufferPool, id: usize, value: []const u8) !void {
        try self.values.items[id].resize(self.allocator, value.len);
        std.mem.copy(u8, self.values.items[id].items, value);
    }

    pub fn get(self: *BufferPool, id: usize) []const u8 {
        return self.values.items[id].items;
    }

    pub fn copy(self: *BufferPool, id: usize, value: []const u8) ![]const u8 {
        try self.set(id, value);
        return self.get(id);
    }
};
