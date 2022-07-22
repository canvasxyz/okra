const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const utils = @import("./utils.zig");

const allocator = std.heap.c_allocator;

const LEAF_SIZE: comptime_int = 40;
const NODE_SIZE: comptime_int = 80;
const PAGE_SIZE: comptime_int = 4096;
const PAGE_CONTENT_SIZE: comptime_int = 4080;
const PAGE_LEAF_CAPACITY: comptime_int = 102;
const PAGE_NODE_CAPACITY: comptime_int = 51;

pub const Leaf = packed struct {
  value: [32]u8,
  timestamp: u64,

  fn leq(self: *const Leaf, other: *const Leaf) bool {
    if (self.timestamp < other.timestamp) {
      return true;
    } else if (self.timestamp == other.timestamp) {
      return utils.hash_leq(&self.value, &other.value);
    } else {
      return false;
    }
  }
};

test "test leaf comparison" {
  const a = Leaf {
    .timestamp = 1,
    .value = try utils.parse_hash("0000000000000000000000000000000000000000000000000000000000000000"),
  };
  
  const b = Leaf {
    .timestamp = 3,
    .value = try utils.parse_hash("0000000000000000000000000000000000000000000000000000000000000000"),
  };

  const c = Leaf {
    .timestamp = 3,
    .value = try utils.parse_hash("0000000000000000000000000000000000000000000000000000000000000001"),
  };

  try expect(Leaf.leq(a, b) == true);
  try expect(Leaf.leq(b, a) == false);
  try expect(Leaf.leq(b, c) == true);
  try expect(Leaf.leq(c, b) == false);
  try expect(Leaf.leq(a, a) == true);
  try expect(Leaf.leq(b, b) == true);
  try expect(Leaf.leq(b, b) == true);
}

const TERMINAL_LEAF = Leaf {
  .value = utils.ZERO_HASH,
  .timestamp = 0xFFFFFFFFFFFFFFFF,
}

// It's important that .leaf is last in the struct
// beacuse we use it for optimizations later.
const Node = packed struct {
  hash: [32]u8,
  page_id: u64,
  leaf: Leaf,
};

test "validate node and leaf sizes" {
  comptime {
    try expect(@sizeOf(Leaf) == LEAF_SIZE);
    try expect(@sizeOf(Node) == NODE_SIZE);
  }
}

const TOMBSTONE_FLAG: u32 = 0xFFFFFFFF;

const Page = packed struct {
  meta: u32,
  padding: [2]u8,
  height: u8,
  count: u8,
  content: [PAGE_CONTENT_SIZE]u8,
  next_id: u64,

  fn leaf_content(self: *const Page) []Leaf {
    return @bitCast([PAGE_LEAF_CAPACITY]Leaf, self.content)[0..self.count];
  }

  fn node_content(self: *const Page) []Node {
    return @bitCast([PAGE_NODE_CAPACITY]Node, self.content)[0..self.count];
  }

  fn get_capacity(self: *const Page) u8 {
    if (self.height == 0) {
      return PAGE_LEAF_CAPACITY;
    } else {
      return PAGE_NODE_CAPACITY;
    }
  }

  fn get_last_leaf(self: *Page) *const Leaf {
    const buffer = @ptrCast(*[PAGE_LEAF_CAPACITY]Leaf, &self.content);
    return &buffer[PAGE_LEAF_CAPACITY - 1];
  }

  fn find_insert_index(self: *const Page, target: *const Leaf) u8 {
    if (self.height == 0) {
      for (self.leaf_content()) |leaf, i| {
        if (target.leq(&leaf)) {
          return @intCast(u8, i);
        }
      }
    } else {
      for (self.node_content()) |node, i| {
        if (target.leq(&node.leaf)) {
          return @intCast(u8, i);
        }
      }
    }

    @panic("internal error finding insert index");
  }

  fn update_digest(self: *const Page, digest: *Sha256) void {
    if (self.height == 0) {
      for (self.leaf_content()) |leaf| {
        digest.update(leaf.value[0..32]);
      }
    } else {
      for (self.node_content()) |node| {
        digest.update(node.hash[0..32]);
      }
    }
  }
};

test "validate page sizes" {
  comptime {
    try expect(@sizeOf(Page) == PAGE_SIZE);
    try expect(PAGE_LEAF_CAPACITY * LEAF_SIZE == PAGE_CONTENT_SIZE);
    try expect(PAGE_NODE_CAPACITY * NODE_SIZE == PAGE_CONTENT_SIZE);
  }
}

const MAGIC: u32 = 0x6b6d7374;
const FANOUT_THRESHHOLD = 0x18;

const Header = packed struct {
  magic: u32,
  major_version: u8,
  minor_version: u8,
  patch_version: u8,
  fanout_threshhold: u8,
  root_id: u64,
  root_hash: [32]u8,
  leaf_count: u64,
  page_count: u64,
  height: u32,
  graveyard_size: u32,
  graveyard: [504]u64,

  fn create() !*Header {
    const header = try allocator.create(Header);
    header.magic = MAGIC;
    header.major_version = 0;
    header.minor_version = 0;
    header.patch_version = 0;
    header.fanout_threshhold = FANOUT_THRESHHOLD;
    header.root_id = 1;
    header.root_hash = utils.ZERO_HASH;
    header.leaf_count = 0;
    header.page_count = 1;
    header.height = 1;
    header.graveyard_size = 0;
    return header;
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
  page_buffer: *[PAGE_SIZE]u8,
  page_content_buffer: *[PAGE_CONTENT_SIZE]u8,
  splice_buffer: *[PAGE_CONTENT_SIZE]u8,

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
    tree.page_buffer = try allocator.create([PAGE_SIZE]u8);
    tree.page_content_buffer = try allocator.create([PAGE_CONTENT_SIZE]u8);
    tree.splice_buffer = try allocator.create([PAGE_CONTENT_SIZE]u8);
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
    tree.header = try Header.create();

    tree.page_buffer = try allocator.create([PAGE_SIZE]u8);
    tree.page_content_buffer = try allocator.create([PAGE_CONTENT_SIZE]u8);
    tree.splice_buffer = try allocator.create([PAGE_CONTENT_SIZE]u8);

    const root = tree.create_page(0);
    const root_leaf_content = root.leaf_content();
    root_leaf_content[0] = TERMINAL_LEAF;

    Sha256.hash(ZERO_HASH[0..32], &tree.header.root_hash, .{});

    try tree.write_header();
    try tree.flush_page_buffer(tree.header.root_id);

    return tree;
  }

  fn create_page(self: *Tree, height: u8) *Page {
    const page = @ptrCast(*Page, self.page_buffer);
    page.meta = 0;
    page.height = height;
    page.count = 0;
    page.next_id = 0;
    return page;
  }

  pub fn close(self: *Tree) void {
    self.file.close();
    allocator.destroy(self.header);
    allocator.destroy(self.page_buffer);
    allocator.destroy(self.page_content_buffer);
    allocator.destroy(self.splice_buffer);
    allocator.destroy(self);
  }

  pub fn insert(self: *Tree, leaf: *const Leaf) !void {
    try self.insert_into_page(self.header.root_id, leaf, &self.header.root_hash);
    try self.write_header();
  }

  fn scan_page_list(self: *Tree, page_id: u64, leaf: *const Leaf, digest: *Sha256) !u64 {
    // The first step is scanning horizontally over the linked list
    // of pages to find the one that the value belongs in.
    // The linked list is just length 1 on expectation but we gotta do it anyway.
    var target_page_id = page_id;
    var target_page = try self.open_page_buffer(page_id);
    while (target_page.next_id != 0) {
      const last_leaf = target_page.get_last_leaf();
      if (leaf.leq(last_leaf)) {
        break;
      } else {
        target_page.update_digest(&digest);
        target_page_id = target_page.next_id;
        target_page = try self.open_page_buffer(target_page.next_id);
      }
    }

    return target_page_id;
  }

  fn insert_leaf(self: *Tree, page_id: u64, leaf: *const Leaf, page_hash: *[32]u8) !void {

  }

  fn insert_node(self: *Tree, page_id: u64, leaf: *const Leaf) ![]Node {
    var digest = Sha256.init(.{});

    const target_page_id = self.scan_page_list(page_id, leaf, digest);
    var target_page = self.page();

    const height = target_page.height;
    const capacity = target_page.get_capacity();

    // Alright - at this point, we've scanned forward through the linked
    // list of pages and found the one that we're going to insert into.
    // Now we have to find the right index within the page.
    const index = target_page.find_insert_index(leaf);

    if (height > 0) {
      const node = target_page.node_content()[index];
      const splice = try self.insert_node(node.page_id, leaf, &node.hash);
      // const  = @ptrCast(*[PAGE_NODE_CAPACITY]Node, self.content_buffer)[0..spliced_count];

      target_page = try self.open_page_buffer(target_page_id);
    }
  }

  fn insert_into_page(self: *Tree, page_id: u64, leaf: *const Leaf, page_hash: *[32]u8) !void {
    var digest = Sha256.init(.{});

    const target_page_id = self.scan_page_list(page_id, leaf, digest);
    const target_page = self.page();

    const height = target_page.height;

    // Alright - at this point, we've scanned forward through the linked
    // list of pages and found the one that we're going to insert into.
    // Now we have to find the right index within the page.
    const index = target_page.find_insert_index(leaf);
    const capacity = target_page.get_capacity();

    if (index == capacity) {
      target_page.update_digest(&digest);
      
      if (target_page.next_id == 0) {
        // create a new page!!
        const new_page_id = self.get_page_id();
        target_page.next_id = new_page_id;
        try self.flush_page_buffer(target_page_id);
        const new_page = self.create_page(height);

      } else {
        // shift the entire chain over :(
      }
    }

    if (height == 0) {

    }



    if (index < capacity) {
      const count = target_page.count;
      const tail_length = count - index;
      
      // this is a little hacky - we want the slice to cover
      // the new range so we increment the count first since
      // leaf_content uses .count internally.
      target_page.count += 1;
      const slice = target_page.leaf_content();

      if (target_page.height == 0) {
        if (tail_length > 0) {
          const leaf_buffer = self.leaf_buffer();
          std.mem.copy(Leaf, buffer[0..tail_length], slice[index..count]);
          std.mem.copy(Leaf, slice[index+1..count+1], buffer[0..tail_length]);
        }
        slice[index] = leaf.*;
      } else {
        @panic("not implemented");
      }

      try self.flush_page_buffer(page_id);

      self.header.leaf_count += 1;

      target_page.update_digest(&digest);
    } else {
      // split page into continuation list..
      @panic("not implemented");
    }

    digest.final(page_hash);
  }



  fn node_splice(self: *Tree, page_id: u64, index: u8, values: []Node) !void {
    const page = self.page();
    assert(page.height > 0);

    const content = @bitCast([PAGE_NODE_CAPACITY]Node, page.content);
    const buffer = self.node_buffer();
    const buffer_length = splice(Node, content, page.count, index, values, buffer);
  }

  fn leaf_splice(self: *Tree, page_id: u64, index: u8, values: []Leaf) !void {
    const page = self.page();
    assert(page.height == 0);

    const content = @bitCast([PAGE_LEAF_CAPACITY]Leaf, page.content);
    const buffer = self.leaf_buffer();
    const buffer_length = splice(Node, content, page.count, index, values, buffer);
  }

  fn shift_page_contents(self: *Tree, page_id: u64, page: *Page, index: u8) !void {
    const capacity = page.get_capacity();

    if (page.count == capacity) {
      @panic("not implemented");
    } else {

    }

    const buffer = self.leaf_buffer();
    std.mem.copy(Leaf, buffer[0..tail_length], slice[index..count]);
    std.mem.copy(Leaf, slice[index+1..count+1], buffer[0..tail_length]);
  }

  fn write_header(self: *Tree) !void {
    try self.file.seekTo(0);
    const header_bytes = @ptrCast(*[PAGE_SIZE]u8, self.header);
    try self.file.writeAll(header_bytes[0..PAGE_SIZE]);
  }

  fn flush_page_buffer(self: *Tree, page_id: u64) !void {
    try self.file.seekTo(page_id * PAGE_SIZE);
    try self.file.writeAll(self.page_buffer[0..PAGE_SIZE]);
  }

  fn open_page_buffer(self: *Tree, page_id: u64) !*Page {
    assert(page_id > 0);
    try self.file.seekTo(page_id * PAGE_SIZE);
    const bytes_read = try self.file.readAll(self.page_buffer[0..PAGE_SIZE]);
    assert(bytes_read == PAGE_SIZE);
    return self.page();
  }

  fn get_page_id(self: *Tree) u64 {
    if (self.header.graveyard_size > 0) {
      const tombstone_index = self.header.graveyard_size - 1;
      self.header.graveyard_size -= 1;
      const tombstone_id = self.header.graveyard[tombstone_index];
      self.header.graveyard[tombstone_index] = 0;
      return tombstone_id;
    } else {
      return self.header.page_count + 1;
    }
  }

  fn page(self: *Tree) *Page {
    return @ptrCast(*Page, self.page_buffer);
  }

  fn node_buffer(self: *Tree) *[PAGE_NODE_CAPACITY] {
    return @ptrCast(*[PAGE_NODE_CAPACITY]Node, self.page_content_buffer);
  }

  fn leaf_buffer(self: *Tree) *[PAGE_LEAF_CAPACITY] {
    return @ptrCast(*[PAGE_LEAF_CAPACITY]Leaf, self.page_content_buffer)
  }

  pub fn print_pages(self: *Tree) !void {
    const stat = try self.file.stat();
    assert(stat.size % PAGE_SIZE == 0);
    assert(stat.size >= PAGE_SIZE * 2);

    const page_count = (stat.size / PAGE_SIZE) - 1;
    std.log.info("----------------------------------", .{});
    std.log.info("{d} bytes (header + {} pages)", .{ stat.size, page_count });
    std.log.info("HEADER ---------------------------", .{});
    std.log.info("  major_version: {d}", .{ self.header.major_version });
    std.log.info("  minor_version: {d}", .{ self.header.minor_version });
    std.log.info("  patch_version: {d}", .{ self.header.patch_version });
    std.log.info("  fanout_threshhold: {d}", .{ self.header.fanout_threshhold });
    std.log.info("  root_id: {d}", .{ self.header.root_id });
    std.log.info("  root_hash: 0x{s}", .{ utils.print_hash(self.header.root_hash) });
    std.log.info("  leaf_count: {d}", .{ self.header.leaf_count });
    std.log.info("  height: {d}", .{ self.header.height });
    std.log.info("  graveyard_size: {d}", .{ self.header.graveyard_size });

    var tombstone_index: u64 = 0;
    while (tombstone_index < self.header.graveyard_size) : (tombstone_index += 1) {
      const tombstone_id = self.header.graveyard[tombstone_index];
      std.log.info("    tombstone: {d}", .{ tombstone_id });
    }

    std.log.info("END OF HEADER --------------------", .{});
    
    var page_id: u64 = 1;
    while (page_id <= page_count) : (page_id += 1) {
      const page = try self.open_page_buffer(page_id);
      const count = page.count;
      std.log.info("PAGE {d} | level {d} | {d} cells", .{ page_id, page.height, count });
      if (page.height == 0) {
        assert(count <= PAGE_LEAF_CAPACITY);
        for (page.leaf_content()) |leaf| {
          const value = try utils.print_hash(leaf.value);
          std.log.info("  0x{s} @ {d}", .{ value, leaf.timestamp });
        }
      } else {
        assert(count <= PAGE_NODE_CAPACITY);
        for (page.node_content()) |node| {
          const hash = try utils.print_hash(node.hash);
          const value = try utils.print_hash(node.leaf.value);
          std.log.info("  0x{s} -> {d} (0x{s} @ {d})", .{ hash, node.page_id, value, node.leaf.timestamp });
        }
      }

      if (page.next_id > 0) {
        std.log.info("CONTINUED IN PAGE {d}", .{ page.next_id });
      }

      std.log.info("END OF PAGE {d}", .{ page_id });
    }
  }
};

