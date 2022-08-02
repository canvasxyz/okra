const std = @import("std");
const expect = std.testing.expect;

const Node = @import("./node.zig").Node;

const constants = @import("./constants.zig");
const utils = @import("./utils.zig");

const LeafParseError = error {
  DelimiterNotFound,
};

pub const Leaf = packed struct {
  timestamp_bytes: [8]u8,
  value: [32]u8,

  pub fn get_timestamp(self: *const Leaf) u64 {
    return std.mem.readIntLittle(u64, &self.timestamp_bytes);
  }

  pub fn set_timestamp(self: *Leaf, timestamp: u64) void {
    std.mem.writeIntLittle(u64, &self.timestamp_bytes, timestamp);
  }

  pub fn parse(input: []const u8) !Leaf {
    const indexOf = std.mem.indexOf(u8, input, ":");
    if (indexOf) |index| {
      var leaf = Leaf{ .timestamp_bytes = undefined, .value = undefined };
      leaf.value = try utils.parse_hash(input[index+1..input.len]);
      const t = try std.fmt.parseUnsigned(u64, input[0..index], 10);
      std.mem.writeIntLittle(u64, &leaf.timestamp_bytes, t);
      return leaf;
    } else {
      return LeafParseError.DelimiterNotFound;
    }
  }

  pub fn derive_node(self: *const Leaf, id: u32) Node {
    var node = Node.create(id);
    node.leaf_timestamp_bytes = self.timestamp_bytes;
    std.mem.copy(u8, &node.leaf_value_prefix, self.value[0..4]);
    return node;
  }
};

test "validate leaf size" {
  comptime {
    try expect(@sizeOf(Leaf) == constants.LEAF_SIZE);
  }
}