const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const utils = @import("./utils.zig");

const allocator = std.heap.c_allocator;

const LEAF_SIZE: comptime_int = 40;
const NODE_SIZE: comptime_int = 48;
// const PAGE_SIZE: comptime_int = 4096;
// const PAGE_CONTENT_SIZE: comptime_int = 4080;
// const PAGE_LEAF_CAPACITY: comptime_int = 102;
// const PAGE_NODE_CAPACITY: comptime_int = 85;
const PAGE_SIZE: comptime_int = 256;
const PAGE_CONTENT_SIZE: comptime_int = 240;
const PAGE_LEAF_CAPACITY: comptime_int = 6;
const PAGE_NODE_CAPACITY: comptime_int = 5;

const LeafParseError = error {
  DelimiterNotFound,
};

pub const Leaf = packed struct {
  timestamp_bytes: [8]u8,
  value: [32]u8,

  fn get_timestamp(self: *const Leaf) u64 {
    return std.mem.readIntLittle(u64, &self.timestamp_bytes);
  }

  fn set_timestamp(self: *Leaf, timestamp: u64) void {
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
};

const TERMINAL_LEAF = Leaf {
  .value = utils.ZERO_HASH,
  .timestamp_bytes = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
};

const Node = packed struct {
  page_id_bytes: [4]u8,
  hash: [32]u8 = utils.ZERO_HASH,
  leaf_timestamp_bytes: [8]u8,
  leaf_value_prefix: [4]u8,

  fn get_page_id(self: *const Node) u32 {
    return std.mem.readIntLittle(u32, &self.page_id_bytes);
  }

  fn set_page_id(self: *Node, page_id: u32) void {
    std.mem.writeIntLittle(u32, &self.page_id_bytes, page_id);
  }

  fn get_leaf_timestamp(self: *const Node) u64 {
    return std.mem.readIntLittle(u64, &self.leaf_timestamp_bytes);
  }

  fn set_leaf_timestamp(self: *Node, leaf_timestamp: u64) void {
    std.mem.writeIntLittle(u64, &self.leaf_timestamp_bytes, leaf_timestamp);
  }

  fn get_leaf_value_prefix(self: *const Node) []u8 {
    return self.leaf_value_prefix[0..4];
  }

  fn set_leaf_value_prefix(self: *Node, leaf_value: []u8) void {
    std.mem.copy(u8, &self.leaf_value_prefix[0..4], leaf_value[0..4]);
  }
};

test "validate node and leaf sizes" {
  comptime {
    try expect(@sizeOf(Leaf) == LEAF_SIZE);
    try expect(@sizeOf(Node) == NODE_SIZE);
  }
}

const TOMBSTONE = [_]u8{ 0xff, 0xff };

const Page = packed struct {
  meta: [2]u8,
  sequence_bytes: [8]u8,
  height: u8,
  count: u8,
  content: [PAGE_CONTENT_SIZE]u8,
  next_id_bytes: [4]u8,

  fn get_sequence(self: *const Page) u64 {
    return std.mem.readIntLittle(u32, &self.sequence_bytes);
  }

  fn set_sequence(self: *Page, sequence: u64) void {
    std.mem.writeIntLittle(u64, &self.sequence_bytes, sequence);
  }

  fn get_next_id(self: *const Page) u32 {
    return std.mem.readIntLittle(u32, &self.next_id_bytes);
  }

  fn set_next_id(self: *Page, next_id: u32) void {
    std.mem.writeIntLittle(u32, &self.next_id_bytes, next_id);
  }

  fn capacity(self: *const Page) u8 {
    if (self.height == 0) {
      return PAGE_LEAF_CAPACITY;
    } else {
      return PAGE_NODE_CAPACITY;
    }
  }

  fn leaf_content(self: *Page) *[PAGE_LEAF_CAPACITY]Leaf {
    return @ptrCast(*[PAGE_LEAF_CAPACITY]Leaf, &self.content);
  }

  fn leafs(self: *Page) []Leaf {
    return self.leaf_content()[0..self.count];
  }

  fn node_content(self: *Page) *[PAGE_NODE_CAPACITY]Node {
    return @ptrCast(*[PAGE_NODE_CAPACITY]Node, &self.content);
  }

  fn nodes(self: *Page) []Node {
    return self.node_content()[0..self.count];
  }

  fn leaf_scan(self: *Page, a: u64, a_value: []const u8, digest: *Sha256) u8 {
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
    try expect(@sizeOf(Page) == PAGE_SIZE);
    try expect(PAGE_LEAF_CAPACITY * LEAF_SIZE == PAGE_CONTENT_SIZE);
    try expect(PAGE_NODE_CAPACITY * NODE_SIZE == PAGE_CONTENT_SIZE);
  }
}

const MAGIC = [_]u8{0x6b, 0x6d, 0x73, 0x74};

const FANOUT_THRESHHOLD = 0x18;

// const TOMBSTONE_CAPACITY: comptime_int = 496;
const TOMBSTONE_CAPACITY: comptime_int = 48;

pub const Header = packed struct {
  magic: [4]u8,
  major_version: u8,
  minor_version: u8,
  patch_version: u8,
  fanout_threshhold: u8,
  root_id_bytes: [4]u8,
  root_hash: [32]u8,
  page_count_bytes: [4]u8,
  height_bytes: [4]u8,
  leaf_count_bytes: [8]u8,
  tombstone_count_bytes: [4]u8,
  tombstones: [TOMBSTONE_CAPACITY][4]u8,
  // padding: [2048]u8,

  fn get_root_id(self: *const Header) u32 {
    return std.mem.readIntLittle(u32, &self.root_id_bytes);
  }

  fn set_root_id(self: *Header, root_id: u32) void {
    std.mem.writeIntLittle(u32, &self.root_id_bytes, root_id);
  }

  fn get_page_count(self: *const Header) u32 {
    return std.mem.readIntLittle(u32, &self.page_count_bytes);
  }

  fn set_page_count(self: *Header, page_count: u32) void {
    std.mem.writeIntLittle(u32, &self.page_count_bytes, page_count);
  }

  fn get_height(self: *const Header) u32 {
    return std.mem.readIntLittle(u32, &self.height_bytes);
  }

  fn set_height(self: *Header, height: u32) void {
    std.mem.writeIntLittle(u32, &self.height_bytes, height);
  }

  fn get_leaf_count(self: *const Header) u64 {
    return std.mem.readIntLittle(u64, &self.leaf_count_bytes);
  }

  fn set_leaf_count(self: *Header, leaf_count: u64) void {
    std.mem.writeIntLittle(u64, &self.leaf_count_bytes, leaf_count);
  }

  fn get_tombstone_count(self: *const Header) u32 {
    return std.mem.readIntLittle(u32, &self.tombstone_count_bytes);
  }

  fn set_tombstone_count(self: *Header, tombstone_count: u32) void {
    std.mem.writeIntLittle(u32, &self.tombstone_count_bytes, tombstone_count);
  }

  fn get_tombstone(self: *Header) u32 {
    const count = self.get_tombstone_count();
    if (count > 0) {
      const index = count - 1;
      const id = std.mem.readIntLittle(u32, &self.tombstones[index]);
      self.set_tombstone_count(index);
      return id;
    } else {
      return 0;
    }
  }
};

test "validate header size" {
  comptime {
    try expect(@sizeOf(Header) == PAGE_SIZE);
  }
}

pub const Tree = struct {
  file: std.fs.File,
  header: *Header,
  // root: Node,
  page_id: u32,
  page: *Page,
  content_buffer: *[PAGE_CONTENT_SIZE]u8,
  splice_buffer: []Node,

  pub fn open(path: []const u8) !*Tree {
    const file: std.fs.File = try std.fs.cwd().openFile(path, .{
      .read = true,
      .write = true,
      .lock = std.fs.File.Lock.Exclusive,
    });

    const header_bytes = try allocator.create([PAGE_SIZE]u8);
    const header_bytes_read = try file.readAll(header_bytes[0..PAGE_SIZE]);
    assert(header_bytes_read == PAGE_SIZE);
    const header = @ptrCast(*Header, header_bytes);
    assert(header.magic == MAGIC);

    const tree: *Tree = try allocator.create(Tree);
    tree.file = file;
    tree.header = header;
    // tree.node = Node {
    //   .page_id_bytes = header.root_id_bytes,
    // }

    tree.page_id = 0;
    tree.page = try allocator.create(Page);
    tree.content_buffer = try allocator.create([PAGE_CONTENT_SIZE]u8);
    tree.splice_buffer = try allocator.create([8]Node);

    return tree;
  }

  pub fn create(path: []const u8) !*Tree {
    const file: std.fs.File = try std.fs.cwd().createFile(path, .{
      .read = true,
      .exclusive = true,
      .lock = std.fs.File.Lock.Exclusive,
    });

    const tree: *Tree = try allocator.create(Tree);
    tree.file = file;

    tree.header = try allocator.create(Header);
    tree.header.magic = MAGIC;
    tree.header.major_version = 0;
    tree.header.minor_version = 0;
    tree.header.patch_version = 0;
    tree.header.fanout_threshhold = FANOUT_THRESHHOLD;
    tree.header.root_hash = utils.ZERO_HASH;
    tree.header.set_root_id(1);
    tree.header.set_leaf_count(1);
    tree.header.set_page_count(1);
    tree.header.set_height(1);
    tree.header.set_tombstone_count(0);

    tree.page_id = 1;
    tree.page = try allocator.create(Page);
    tree.content_buffer = try allocator.create([PAGE_CONTENT_SIZE]u8);
    tree.splice_buffer = try allocator.create([PAGE_NODE_CAPACITY]Node);

    tree.page.meta = [_]u8{ 0, 0 };
    tree.page.height = 0;
    tree.page.count = 1;
    tree.page.set_next_id(0);

    const initial_leaf = @ptrCast(*Leaf, &tree.page.content);
    initial_leaf.* = TERMINAL_LEAF;

    Sha256.hash(TERMINAL_LEAF.value[0..32], &tree.header.root_hash, .{});

    try tree.flush_header();
    try tree.flush_page();

    return tree;
  }

  pub fn close(self: *Tree) void {
    self.file.close();
    allocator.destroy(self.header);
    allocator.destroy(self.page);
    allocator.destroy(self.content_buffer);
    allocator.destroy(self.splice_buffer.ptr);
    allocator.destroy(self);
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
      const splice = try self.insert_leaf(node, leaf);
      std.log.info("we sure did split the shit outta that: {d}", .{ splice.len });
    }

    // try self.flush_header();
  }

  // calls to insert_leaf have to leave the node in the first slot of the splice buffer!
  fn insert_leaf(self: *Tree, node: Node, target: *const Leaf, ) ![]Node {
    self.splice_buffer[0] = node;

    const target_timestamp = target.get_timestamp();
    const target_value = target.value[0..32];

    var digest = Sha256.init(.{});
    var target_page_id = Node.get_page_id(&node);
    const target_index = while (target_page_id != 0) {
      try self.open_page(target_page_id);
      const i = self.page.leaf_scan(target_timestamp, target_value, &digest);
      if (i < self.page.count) {
        break i;
      } else {
        target_page_id = self.page.get_next_id();
      }
    } else unreachable;

    digest.update(target_value);

    std.log.info("page id: {d}, index: {d}", .{ target_page_id, target_index });
  
    // now that we've found the place, we take different code paths
    // depending on whether the leaf is a split or not.
    if (self.is_split(target)) {
      // the special case of target_index == 0 and target_page_id == page_id
      // is worth handling separately:
      if ((target_page_id == node.get_page_id()) and (target_index == 0)) {
        // create a new page with the target as the only leaf
        self.page_id = self.get_new_page_id();
        self.page.count = 1;
        self.page.set_next_id(0);

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
        self.splice_buffer[1] = node;
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
      self.splice_buffer[0] = node;
      
      const content = self.page.leaf_content();
      var next_id = self.page.get_next_id();

      if (self.page.count < PAGE_LEAF_CAPACITY) {
        assert(next_id == 0);
        std.mem.copyBackwards(Leaf, content[target_index+1..self.page.count+1], content[target_index..self.page.count]);
        content[target_index].value = target.value;
        content[target_index].timestamp_bytes = target.timestamp_bytes;
        self.page.count += 1;
        try self.flush_page();

        for (content[target_index+1..self.page.count+1]) |leaf| {
          digest.update(&leaf.value);
        }
      } else {
        const buffer = self.leaf_buffer();
        buffer[0] = content[PAGE_LEAF_CAPACITY-1];
        std.mem.copyBackwards(Leaf, content[target_index+1..self.page.count+1], content[target_index..self.page.count]);
        try self.flush_page();

        while (next_id != 0) {
          try self.open_page(next_id);
          next_id = self.page.get_next_id();

          if (self.page.count < PAGE_LEAF_CAPACITY) {
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
            buffer[1] = content[PAGE_LEAF_CAPACITY-1];
            std.mem.copyBackwards(Leaf, content[1..PAGE_LEAF_CAPACITY], content[0..PAGE_LEAF_CAPACITY-1]);
            content[0] = buffer[0];
            try self.flush_page();

            for (content) |leaf| {
              digest.update(&leaf.value);
            }

            self.page_id = new_page_id;
            self.page.count = 1;
            content[0] = buffer[1];
            self.page.set_next_id(0);
            try self.flush_page();

            digest.update(&content[0].value);
          } else {
            buffer[1] = content[PAGE_LEAF_CAPACITY-1];
            std.mem.copyBackwards(Leaf, content[1..PAGE_LEAF_CAPACITY], content[0..PAGE_LEAF_CAPACITY-1]);
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

    const content = self.page.leaf_content();
    const buffer = self.leaf_buffer();

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
      self.page_id = self.get_new_page_id();
      self.page.count = tail_length;

      for (buffer[0..tail_length]) |leaf, i| {
        content[i].timestamp_bytes = leaf.timestamp_bytes;
        content[i].value = leaf.value;
        digest.update(leaf.value[0..32]);
      }

      try self.flush_page();

      return self.page_id;
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
      const remaining_capacity = PAGE_LEAF_CAPACITY - tail_length;
      if (count <= remaining_capacity) {
        assert(next_id == 0);
        std.mem.copy(Leaf, content[tail_length..tail_length+count], buffer[0..count]);
        self.page.count = tail_length + count;
        try self.flush_page();
      } else {
        std.mem.copy(Leaf, content[tail_length..PAGE_LEAF_CAPACITY], buffer[0..remaining_capacity]);
        self.page.count = PAGE_LEAF_CAPACITY;
        tail_length = count - remaining_capacity;
        std.mem.copy(Leaf, buffer[0..tail_length], buffer[remaining_capacity..count]);

        if ((next_id == 0) and (tail_length > 0)) {
          const new_page_id = self.get_new_page_id();

          self.page.set_next_id(new_page_id);
          try self.flush_page();

          self.page_id = new_page_id;
          self.page.count = tail_length;
          std.mem.copy(Leaf, content[0..tail_length], buffer[0..tail_length]);
          self.page.set_next_id(0);
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

  fn flush_header(self: *Tree) !void {
    try self.file.seekTo(0);
    const bytes = @ptrCast(*[PAGE_SIZE]u8, self.header);
    try self.file.writeAll(bytes);
  }

  fn flush_page(self: *Tree) !void {
    try self.file.seekTo(self.page_id * PAGE_SIZE);
    const bytes = @ptrCast(*[PAGE_SIZE]u8, self.page);
    try self.file.writeAll(bytes);
  }

  fn open_page(self: *Tree, page_id: u32) !void {
    assert(page_id > 0);
    if (self.page_id != page_id) {
      try self.file.seekTo(page_id * PAGE_SIZE);
      const bytes = @ptrCast(*[PAGE_SIZE]u8, self.page);
      const bytes_read = try self.file.readAll(bytes);
      assert(bytes_read == PAGE_SIZE);
      self.page_id = page_id;
    }
  }

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

  fn leaf_buffer(self: *Tree) *[PAGE_LEAF_CAPACITY]Leaf {
    return @ptrCast(*[PAGE_LEAF_CAPACITY]Leaf, self.content_buffer);
  }

  // fn is_split(self: *Tree, leaf: *Leaf) bool {
  //   return leaf.value[0] < self.header.fanout_threshhold;
  // }

  pub fn print_pages(self: *Tree) !void {
    const stat = try self.file.stat();
    assert(stat.size % PAGE_SIZE == 0);
    assert(stat.size >= PAGE_SIZE * 2);

    std.log.info("----------------------------------", .{});
    std.log.info("{d} bytes", .{ stat.size });
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

    assert(stat.size / PAGE_SIZE == 1 + self.header.get_page_count());

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
      const count = self.page.count;
      std.log.info("PAGE {d} | level {d} | {d} cells", .{ page_id, self.page.height, count });
      if (self.page.height == 0) {
        assert(count <= PAGE_LEAF_CAPACITY);
        for (self.page.leafs()) |leaf| {
          const value = try utils.print_hash(leaf.value[0..32]);
          std.log.info("  0x{s} @ {d}", .{ value, leaf.get_timestamp() });
        }
      } else {
        assert(count <= PAGE_NODE_CAPACITY);
        for (self.page.nodes()) |node| {
          const hash = try utils.print_hash(node.hash[0..32]);
          const value = try utils.print_hash(node.leaf_value_prefix[0..4]);
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

