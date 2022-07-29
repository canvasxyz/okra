const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const constants = @import("./constants.zig");
const utils = @import("./utils.zig");
const store = @import("./store.zig");

const Header = @import("./header.zig").Header;
const Page = @import("./page.zig").Page;
const Node = @import("./node.zig").Node;
const Leaf = @import("./leaf.zig").Leaf;

const allocator = std.heap.c_allocator;

const TERMINAL_LEAF = Leaf {
  .value = constants.ZERO_HASH,
  .timestamp_bytes = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
};

const FANOUT_THRESHHOLD: u8 = 0x18;



pub const Tree = struct {
  header: *Header,
  page_id: u32,
  page: *Page,
  content_buffer: *[constants.PAGE_CONTENT_SIZE]u8,
  splice_buffer: []Node,

  memory_store: ?*store.MemoryStore,
  file_store: ?*store.FileStore,

  pub fn temp(memory_limit: u32) !*Tree {
    const tree: *Tree = try allocator.create(Tree);
    tree.file_store = null;
    tree.memory_store = try store.MemoryStore.create(allocator, memory_limit);
    
    tree.header = try allocator.create(Header);
    tree.header.init(FANOUT_THRESHHOLD);

    try tree.create_page(tree.header.get_root_id(), 0, 1, 0);

    tree.content_buffer = try allocator.create([constants.PAGE_CONTENT_SIZE]u8);
    tree.splice_buffer = try allocator.create([16]Node);

    const content = tree.page.leaf_content();
    content[0] = TERMINAL_LEAF;

    Sha256.hash(TERMINAL_LEAF.value[0..32], &tree.header.root_hash, .{});

    return tree;
  }

  pub fn open(path: []const u8) !*Tree {
    const tree: *Tree = try allocator.create(Tree);
    tree.header = try allocator.create(Header);
    tree.page = try allocator.create(Page);
    tree.file_store = try store.FileStore.open(allocator, path, tree.header, tree.page);
    tree.memory_store = null;

    assert(tree.header.magic == constants.MAGIC);
    
    tree.content_buffer = try allocator.create([constants.PAGE_CONTENT_SIZE]u8);
    tree.splice_buffer = try allocator.create([16]Node);

    return tree;
  }

  pub fn create(path: []const u8) !*Tree {
    const tree: *Tree = try allocator.create(Tree);
    tree.file_store = try store.FileStore.create(allocator, path);
    tree.memory_store = null;

    tree.header = try allocator.create(Header);
    tree.header.init(FANOUT_THRESHHOLD);

    tree.page = try allocator.create(Page);
    try tree.create_page(tree.header.get_root_id(), 0, 1, 0);

    tree.content_buffer = try allocator.create([constants.PAGE_CONTENT_SIZE]u8);
    tree.splice_buffer = try allocator.create([16]Node);

    const content = tree.page.leaf_content();
    content[0] = TERMINAL_LEAF;

    Sha256.hash(TERMINAL_LEAF.value[0..32], &tree.header.root_hash, .{});

    try tree.flush_header();
    try tree.flush_page();

    return tree;
  }

  pub fn close(self: *Tree) void {
    if (self.memory_store) |memory_store| {
      memory_store.close(allocator);
    } else if (self.file_store) |file_store| {
      file_store.close(allocator);
      allocator.destroy(self.page);
    } else {
      @panic("no store configured");
    }

    allocator.destroy(self.header);
    allocator.destroy(self.content_buffer);
    allocator.destroy(self.splice_buffer.ptr);
    allocator.destroy(self);
  }

  fn flush_header(self: *Tree) !void {
    if (self.file_store) |file_store| {
      try file_store.file.seekTo(0);
      const bytes = @ptrCast(*[constants.PAGE_SIZE]u8, self.header);
      try file_store.file.writeAll(bytes);
    }
  }

  fn flush_page(self: *Tree) !void {
    if (self.file_store) |file_store| {
      try file_store.write_page(self.page_id, self.page);
    }
  }

  fn open_page(self: *Tree, page_id: u32) !void {
    if (self.page_id != page_id) {
      if (self.file_store) |file_store| {
        try file_store.open_page(page_id, self.page);
      } else if (self.memory_store) |memory_store| {
        self.page = memory_store.get_page(page_id);
      }

      self.page_id = page_id;
    }
  }

  fn create_page(self: *Tree, page_id: u32, height: u8, count: u8, next_id: u32) !void {
    if (self.memory_store) |memory_store| {
      self.page = try memory_store.create_page(allocator, page_id);
    }

    self.page.set_meta(0x0000);
    self.page.height = height;
    self.page.count = count;
    self.page.set_next_id(next_id);
    self.page_id = page_id;
  }

  fn get_new_page_id(self: *Tree) u32 {
    const tombstone = self.header.get_tombstone();
    if (tombstone == 0) {
      const new_page_id = self.header.get_page_count() + 1;
      self.header.set_page_count(new_page_id);
      return new_page_id;
    } else {
      return tombstone;
    }
  }

  fn is_split(self: *const Tree, leaf: *const Leaf) bool {
    return leaf.value[0] < self.header.fanout_threshhold;
  }

  pub fn insert(self: *Tree, leaf: *const Leaf) !void {
    const height = self.header.get_height();

    if (height > 1) {
      @panic("not implemented");
    } else {
      const node = Node {
        .page_id_bytes = self.header.root_id_bytes,
        .hash = self.header.root_hash,
        .leaf_timestamp_bytes = TERMINAL_LEAF.timestamp_bytes,
        .leaf_value_prefix = [_]u8{ 0, 0, 0, 0 },
      };

      const splice = try self.insert_leaf(&node, leaf);
      const leaf_count = self.header.get_leaf_count();
      self.header.set_leaf_count(leaf_count + 1);

      std.log.info("we sure did insert the shit outta that: {d}", .{ splice.len });
      if (splice.len == 1) {
        self.header.root_id_bytes = splice[0].page_id_bytes;
        self.header.root_hash = splice[0].hash;
      } else {
        @panic("not implemented");
      }
    }

    try self.flush_header();
  }

  fn insert_leaf(self: *Tree, node: *const Node, target: *const Leaf, ) ![]Node {
    const target_timestamp = target.get_timestamp();

    var digest = Sha256.init(.{});
    var target_page_id = node.get_page_id();
    const target_index = while (target_page_id != 0) {
      try self.open_page(target_page_id);
      const i = self.page.leaf_scan(target_timestamp, &target.value, &digest);
      if (i < self.page.count) {
        break i;
      } else {
        target_page_id = self.page.get_next_id();
      }
    } else unreachable;

    digest.update(&target.value);

    std.log.info("page id: {d}, index: {d}", .{ target_page_id, target_index });
  
    // now that we've found the place, we take different code paths
    // depending on whether the leaf is a split or not.
    if (self.is_split(target)) {
      // the special case of target_index == 0 and target_page_id == page_id
      // is worth handling separately:
      if ((target_page_id == node.get_page_id()) and (target_index == 0)) {
        // create a new page with the target as the only leaf
        try self.create_page(self.get_new_page_id(), 0, 1, 0);

        const content = self.page.leaf_content();
        content[0].value = target.value;
        content[0].timestamp_bytes = target.timestamp_bytes;
        try self.flush_page();

        // hash the single-leaf page
        const new_node = &self.splice_buffer[0];
        new_node.set_page_id(self.page_id);
        new_node.set_leaf_timestamp(target_timestamp);
        Sha256.hash(target.value[0..32], &new_node.hash, .{});
        std.mem.copy(u8, new_node.leaf_value_prefix[0..4], target.value[0..4]);

        // copy the original node verbatim into the second slot
        self.splice_buffer[1] = node.*;
      } else {
        const split_node = &self.splice_buffer[1];
        var split_digest = Sha256.init(.{});
        const split_page_id = try self.split_leaf_page(target_index, target, &split_digest);
        split_node.set_page_id(split_page_id);
        split_digest.final(&split_node.hash);
        split_node.leaf_timestamp_bytes = node.leaf_timestamp_bytes;
        split_node.leaf_value_prefix = node.leaf_value_prefix;
      }

      return self.splice_buffer[0..2];
    } else {
      self.splice_buffer[0].page_id_bytes = node.page_id_bytes;
      self.splice_buffer[0].leaf_timestamp_bytes = node.leaf_timestamp_bytes;
      self.splice_buffer[0].leaf_value_prefix = node.leaf_value_prefix;
      
      const content = self.page.leaf_content();
      var next_id = self.page.get_next_id();

      if (self.page.count < constants.PAGE_LEAF_CAPACITY) {
        assert(next_id == 0);
        std.mem.copyBackwards(Leaf, content[target_index+1..self.page.count+1], content[target_index..self.page.count]);
        content[target_index].value = target.value;
        content[target_index].timestamp_bytes = target.timestamp_bytes;
        self.page.count += 1;
        try self.flush_page();

        for (content[target_index+1..self.page.count]) |leaf| {
          digest.update(&leaf.value);
        }
      } else {
        const buffer = self.leaf_buffer();
        buffer[0] = content[constants.PAGE_LEAF_CAPACITY-1];
        std.mem.copyBackwards(Leaf, content[target_index+1..self.page.count+1], content[target_index..self.page.count]);
        try self.flush_page();

        while (next_id != 0) {
          try self.open_page(next_id);
          next_id = self.page.get_next_id();

          if (self.page.count < constants.PAGE_LEAF_CAPACITY) {
            assert(next_id == 0);
            std.mem.copyBackwards(Leaf, content[1..self.page.count+1], content[0..self.page.count]);
            content[0] = buffer[0];
            self.page.count += 1;
            try self.flush_page();

            for (content[0..self.page.count]) |leaf| {
              digest.update(&leaf.value);
            }
          } else if (next_id == 0) {
            const new_page_id = self.get_new_page_id();
            self.page.set_next_id(new_page_id);
            buffer[1] = content[constants.PAGE_LEAF_CAPACITY-1];
            std.mem.copyBackwards(Leaf, content[1..constants.PAGE_LEAF_CAPACITY], content[0..constants.PAGE_LEAF_CAPACITY-1]);
            content[0] = buffer[0];
            try self.flush_page();

            for (content) |leaf| {
              digest.update(&leaf.value);
            }

            try self.create_page(new_page_id, 0, 1, 0);
            content[0] = buffer[1];
            try self.flush_page();

            digest.update(&content[0].value);
          } else {
            buffer[1] = content[constants.PAGE_LEAF_CAPACITY-1];
            std.mem.copyBackwards(Leaf, content[1..constants.PAGE_LEAF_CAPACITY], content[0..constants.PAGE_LEAF_CAPACITY-1]);
            content[0] = buffer[0];
            try self.flush_page();

            for (content) |leaf| {
              digest.update(&leaf.value);
            }

            buffer[0] = buffer[1];
          }
        }
      }

      digest.final(&self.splice_buffer[0].hash);

      return self.splice_buffer[0..1];
    }
  }

  fn split_leaf_page(self: *Tree, target_index: u8, target: *const Leaf, digest: *Sha256) !u32 {
    assert(self.page.height == 0);

    const buffer = self.leaf_buffer();
    var content = self.page.leaf_content();

    // save any page data we'll need later
    var next_id = self.page.get_next_id();
    var count = self.page.count;

    // 1. copy remainder of current page into start of buffer and start tracking a new hash
    var tail_length = count - target_index;
    for (content[target_index..count]) |leaf, i| {
      buffer[i] = leaf;
      digest.update(leaf.value[0..32]);
    }

    // 2. write the new leaf and update the page count.
    content[target_index].timestamp_bytes = target.timestamp_bytes;
    content[target_index].value = target.value;
    self.page.count = target_index + 1;
    self.page.set_next_id(0);

    // 3. flush the current page
    try self.flush_page();
    
    // 5a. there are no more pages in the list; we must create a new one.
    // this could *probably* be merged with the while loop in 5b but it felt
    // easier to write them separately here.
    if (next_id == 0) {
      const new_page_id = self.get_new_page_id();
      try self.create_page(new_page_id, 0, tail_length, 0);
      content = self.page.leaf_content();

      for (buffer[0..tail_length]) |leaf, i| {
        content[i].timestamp_bytes = leaf.timestamp_bytes;
        content[i].value = leaf.value;
        digest.update(leaf.value[0..32]);
      }

      try self.flush_page();

      return new_page_id;
    }

    
    // 5b. if there are more pages in the list, we have to shift their content backwards,
    // possibly writing a new page at the end.

    const split_page_id = next_id;

    // at this point, the buffer holds tail_length leaves from the previous page.
    while (next_id != 0) {
      try self.open_page(next_id);
      count = self.page.count;
      next_id = self.page.get_next_id();

      // swap content and buffer values; update the new digest
      for (content[0..count]) |leaf, i| {
        digest.update(&leaf.value);
        content[i] = buffer[i];
        buffer[i] = leaf;
      }

      // now the page content starts with the tail_length leaves from the previous page.
      // we want to write the head of the buffer back to the tail of the page.
      const remaining_capacity = constants.PAGE_LEAF_CAPACITY - tail_length;
      if (count <= remaining_capacity) {
        assert(next_id == 0);
        std.mem.copy(Leaf, content[tail_length..tail_length+count], buffer[0..count]);
        self.page.count = tail_length + count;
        try self.flush_page();
      } else {
        std.mem.copy(Leaf, content[tail_length..constants.PAGE_LEAF_CAPACITY], buffer[0..remaining_capacity]);
        self.page.count = constants.PAGE_LEAF_CAPACITY;
        tail_length = count - remaining_capacity;
        std.mem.copy(Leaf, buffer[0..tail_length], buffer[remaining_capacity..count]);

        if ((next_id == 0) and (tail_length > 0)) {
          const new_page_id = self.get_new_page_id();

          self.page.set_next_id(new_page_id);
          try self.flush_page();

          try self.create_page(new_page_id, 0, tail_length, 0);
          content = self.page.leaf_content();
          std.mem.copy(Leaf, content[0..tail_length], buffer[0..tail_length]);
          try self.flush_page();
        } else {
          try self.flush_page();
        }
      }
    }

    return split_page_id;
  }

  // fn insert_node(self: *Tree, page_id: u64, leaf: *const Leaf) ![]Node {
  //   var digest = Sha256.init(.{});

  //   const target_page_id = self.scan_page_list(page_id, leaf, digest);
  //   var target_page = self.page();

  //   const height = target_page.height;
  //   const capacity = target_page.capacity();

  //   // Alright - at this point, we've scanned forward through the linked
  //   // list of pages and found the one that we're going to insert into.
  //   // Now we have to find the right index within the page.
  //   const index = target_page.find_insert_index(leaf);

  //   if (height > 0) {
  //     const node = target_page.node_content()[index];
  //     const splice = try self.insert_node(node.page_id, leaf, &node.hash);
  //     // const  = @ptrCast(*[PAGE_NODE_CAPACITY]Node, self.content_buffer)[0..spliced_count];

  //     target_page = try self.open_page(target_page_id);
  //   }
  // }

  // fn node_splice(self: *Tree, page_id: u64, index: u8, values: []Node) !void {
  //   const page = self.page();
  //   assert(page.height > 0);

  //   const content = @bitCast([PAGE_NODE_CAPACITY]Node, page.content);
  //   const buffer = self.node_buffer();
  //   const buffer_length = splice(Node, content, page.count, index, values, buffer);
  // }

  // fn leaf_splice(self: *Tree, page_id: u64, index: u8, values: []Leaf) !void {
  //   const page = self.page();
  //   assert(page.height == 0);

  //   const content = @bitCast([PAGE_LEAF_CAPACITY]Leaf, page.content);
  //   const buffer = self.leaf_buffer();
  //   const buffer_length = splice(Leaf, content, page.count, index, values, buffer);
  // }

  // fn get_page_id(self: *Tree) u32 {
  //   if (self.header.graveyard_size > 0) {
  //     const tombstone_index = self.header.graveyard_size - 1;
  //     self.header.graveyard_size -= 1;
  //     const tombstone_id = self.header.graveyard[tombstone_index];
  //     self.header.graveyard[tombstone_index] = 0;
  //     return tombstone_id;
  //   } else {
  //     return self.header.page_count + 1;
  //   }
  // }

  // fn node_buffer(self: *Tree) *[PAGE_NODE_CAPACITY] {
  //   return @ptrCast(*[PAGE_NODE_CAPACITY]Node, self.content_buffer);
  // }

  fn leaf_buffer(self: *Tree) *[constants.PAGE_LEAF_CAPACITY]Leaf {
    return @ptrCast(*[constants.PAGE_LEAF_CAPACITY]Leaf, self.content_buffer);
  }

  // fn is_split(self: *Tree, leaf: *Leaf) bool {
  //   return leaf.value[0] < self.header.fanout_threshhold;
  // }

  pub fn print_pages(self: *Tree) !void {

    if (self.file_store) |file_store| {
      const stat = try file_store.file.stat();
      assert(stat.size % constants.PAGE_SIZE == 0);
      assert(stat.size >= constants.PAGE_SIZE * 2);

      std.log.info("----------------------------------", .{});
      std.log.info("{d} bytes", .{ stat.size });
    }
    
    std.log.info("HEADER ---------------------------", .{});
    std.log.info("  magic: 0x{X}{X}{X}{X}", .{ self.header.magic[0], self.header.magic[1], self.header.magic[2], self.header.magic[3] });
    std.log.info("  major_version: {d}", .{ self.header.major_version });
    std.log.info("  minor_version: {d}", .{ self.header.minor_version });
    std.log.info("  patch_version: {d}", .{ self.header.patch_version });
    std.log.info("  fanout_threshhold: {d}", .{ self.header.fanout_threshhold });
    std.log.info("  root_id: {d}", .{ self.header.get_root_id() });
    std.log.info("  root_hash: 0x{s}", .{ utils.print_hash(self.header.root_hash[0..32]) });
    std.log.info("  page_count: {d}", .{ self.header.get_page_count() });
    std.log.info("  height: {d}", .{ self.header.get_height() });
    std.log.info("  leaf_count: {d}", .{ self.header.get_leaf_count() });
    std.log.info("  tombstone_count: {d}", .{ self.header.get_tombstone_count() });

    

    const tombstone_count = self.header.get_tombstone_count();
    var tombstone_index: u32 = 0;
    while (tombstone_index < tombstone_count) : (tombstone_index += 1) {
      const tombstone_id = std.mem.readIntLittle(u32, &self.header.tombstones[tombstone_index]);
      std.log.info("    tombstone: {d}", .{ tombstone_id });
    }

    std.log.info("END OF HEADER --------------------", .{});
    
    var page_id: u32 = 1;
    while (page_id <= self.header.get_page_count()) : (page_id += 1) {
      try self.open_page(page_id);
      if (self.page.get_meta() == constants.TOMBSTONE) {
        std.log.info("PAGE {d} (deleted)", .{ page_id });
        continue;
      }

      const count = self.page.count;
      std.log.info("PAGE {d} | level {d} | {d} cells", .{ page_id, self.page.height, count });
      if (self.page.height == 0) {
        assert(count <= constants.PAGE_LEAF_CAPACITY);
        for (self.page.leafs()) |leaf| {
          const value = try utils.print_hash(&leaf.value);
          std.log.info("  0x{s} @ {d}", .{ value, leaf.get_timestamp() });
        }
      } else {
        assert(count <= constants.PAGE_NODE_CAPACITY);
        for (self.page.nodes()) |node| {
          const hash = try utils.print_hash(&node.hash);
          const value = try utils.print_hash(&node.leaf_value_prefix);
          std.log.info("  0x{s} -> {d} ({d}:{s}...)", .{ hash, node.get_page_id(), node.get_leaf_timestamp(), value });
        }
      }

      const next_id = self.page.get_next_id();
      if (next_id > 0) {
        std.log.info("CONTINUED IN PAGE {d}", .{ next_id });
      }

      std.log.info("END OF PAGE {d}", .{ page_id });
    }
  }
};

