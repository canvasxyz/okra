const std = @import("std");

const expect = std.testing.expect;
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const constants = @import("./constants.zig");

const Node = @import("./node.zig").Node;
const Leaf = @import("./leaf.zig").Leaf;

pub const Page = packed struct {
  meta_bytes: [2]u8,
  sequence_bytes: [8]u8,
  level: u8,
  count: u8,
  content: [constants.PAGE_CONTENT_SIZE]u8,
  next_id_bytes: [4]u8,

  // allocates on the stack; used mostly by test runners
  pub fn create(comptime T: type, level: u8, content: []const T, next_id: u32) Page {
    var page = Page {
      .meta_bytes = [_]u8{ 0, 0 },
      .sequence_bytes = undefined,
      .level = level,
      .count = @intCast(u8, content.len),
      .content = undefined,
      .next_id_bytes = undefined,
    };
    
    const page_content = @ptrCast(*[@divExact(constants.PAGE_CONTENT_SIZE, @sizeOf(T))]T, &page.content);
    std.mem.copy(T, page_content[0..content.len], content);
    page.set_next_id(next_id);
    return page;
  }

  pub fn get_meta(self: *const Page) u16 {
    return std.mem.readIntLittle(u16, &self.meta_bytes);
  }

  pub fn set_meta(self: *Page, meta: u16) void {
    std.mem.writeIntLittle(u16, &self.meta_bytes, meta);
  }

  pub fn get_next_id(self: *const Page) u32 {
    return std.mem.readIntLittle(u32, &self.next_id_bytes);
  }

  pub fn set_next_id(self: *Page, next_id: u32) void {
    std.mem.writeIntLittle(u32, &self.next_id_bytes, next_id);
  }

  pub fn capacity(self: *const Page) u8 {
    if (self.level == 0) {
      return constants.PAGE_LEAF_CAPACITY;
    } else {
      return constants.PAGE_NODE_CAPACITY;
    }
  }

  pub fn leaf_content(self: *Page) *[constants.PAGE_LEAF_CAPACITY]Leaf {
    return @ptrCast(*[constants.PAGE_LEAF_CAPACITY]Leaf, &self.content);
  }

  pub fn leafs(self: *Page) []Leaf {
    return self.leaf_content()[0..self.count];
  }

  pub fn node_content(self: *Page) *[constants.PAGE_NODE_CAPACITY]Node {
    return @ptrCast(*[constants.PAGE_NODE_CAPACITY]Node, &self.content);
  }

  pub fn nodes(self: *Page) []Node {
    return self.node_content()[0..self.count];
  }

  pub fn leaf_scan(self: *Page, target: *const Leaf, digest: *Sha256) u8 {
    assert(self.level == 0);

    const a = target.get_timestamp();
    for (self.leaf_content()) |leaf, i| {
      const b = leaf.get_timestamp();
      if ((a < b) or ((a == b) and std.mem.lessThan(u8, &target.value, &leaf.value))) {
        return @intCast(u8, i);
      } else {
        digest.update(&leaf.value);
      }
    }

    // TODO: replace self.count with capacity or something
    assert(self.get_next_id() != 0);
    return self.count;
  }

  fn node_scan(self: *const Page, target: *const Leaf, digest: *Sha256) u8 {
    assert(self.level > 0);

    const a = target.get_timestamp();
    const v = target.value[0..4];
    for (self.node_content()) |node, i| {
      const b = node.get_leaf_timestamp();
      if ((a < b) or ((a == b) and std.mem.lessThan(u8, v, &node.leaf_value_prefix))) {
        return @intCast(u8, i);
      } else {
        digest.update(&node.hash);
      }
    }

    assert(self.get_next_id() != 0);
    return self.count;
  }

  pub fn eql(a: *const Page, b: *const Page) bool {
    return ((a.get_meta() == b.get_meta()) and a.level == b.level and a.count == b.count and a.get_next_id() == b.get_next_id()); 
  }
};

test "validate page sizes" {
  comptime {
    try expect(@sizeOf(Page) == constants.PAGE_SIZE);
  }
}