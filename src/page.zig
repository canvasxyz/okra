const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const expect = std.testing.expect;

const constants = @import("./constants.zig");

const Node = @import("./node.zig").Node;
const Leaf = @import("./leaf.zig").Leaf;

pub const Page = packed struct {
  meta_bytes: [2]u8,
  padding: [8]u8,
  height: u8,
  count: u8,
  content: [constants.PAGE_CONTENT_SIZE]u8,
  next_id_bytes: [4]u8,

  // allocates on the stack; used mostly by test runners
  pub fn create(comptime T: type, height: u8, content: []const T, next_id: u32) Page {
    var page = Page {
      .meta_bytes = [_]u8{ 0, 0 },
      .padding = undefined,
      .height = height,
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
    if (self.height == 0) {
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

  pub fn leaf_scan(self: *Page, a: u64, a_value: []const u8, digest: *Sha256) u8 {
    for (self.leaf_content()) |leaf, i| {
      const b = leaf.get_timestamp();
      if ((a < b) or ((a == b) and std.mem.lessThan(u8, a_value, leaf.value[0..32]))) {
        return @intCast(u8, i);
      } else {
        digest.update(&leaf.value);
      }
    }

    return self.count;
  }

  pub fn eql(a: *const Page, b: *const Page) bool {
    return ((a.get_meta() == b.get_meta()) and a.height == b.height and a.count == b.count and a.get_next_id() == b.get_next_id()); 
  }

  // fn node_scan(self: *const Page, a: u64, a_value: []const u8, digest: *Sha256) u8 {
  //   for (self.node_content()) |node, i| {
  //     const b = node.get_leaf_timestamp();
  //     if ((a < b) or ((a == b) and std.mem.lessThan(u8, a_value[0..4], node.get_leaf_value_prefix()))) {
  //       return @intCast(u8, i);
  //     } else {
  //       digest.update(node.hash[0..32]);
  //     }
  //   }

  //   return self.count;
  // }
};

test "validate page sizes" {
  comptime {
    try expect(@sizeOf(Page) == constants.PAGE_SIZE);
  }
}