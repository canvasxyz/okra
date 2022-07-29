const std = @import("std");
const expect = std.testing.expect;

const constants = @import("./constants.zig");

pub const Node = packed struct {
  page_id_bytes: [4]u8,
  hash: [32]u8,
  leaf_timestamp_bytes: [8]u8,
  leaf_value_prefix: [4]u8,

  pub fn get_page_id(self: *const Node) u32 {
    return std.mem.readIntLittle(u32, &self.page_id_bytes);
  }

  pub fn set_page_id(self: *Node, page_id: u32) void {
    std.mem.writeIntLittle(u32, &self.page_id_bytes, page_id);
  }

  pub fn get_leaf_timestamp(self: *const Node) u64 {
    return std.mem.readIntLittle(u64, &self.leaf_timestamp_bytes);
  }

  pub fn set_leaf_timestamp(self: *Node, leaf_timestamp: u64) void {
    std.mem.writeIntLittle(u64, &self.leaf_timestamp_bytes, leaf_timestamp);
  }

  pub fn get_leaf_value_prefix(self: *const Node) []u8 {
    return self.leaf_value_prefix[0..4];
  }

  pub fn set_leaf_value_prefix(self: *Node, leaf_value: []u8) void {
    std.mem.copy(u8, &self.leaf_value_prefix[0..4], leaf_value[0..4]);
  }
};

test "validate node size" {
  comptime {
    try expect(@sizeOf(Node) == constants.NODE_SIZE);
  }
}