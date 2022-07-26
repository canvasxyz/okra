const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const utils = @import("./utils.zig");

const allocator = std.heap.c_allocator;

const LEAF_SIZE: comptime_int = 40;
const NODE_SIZE: comptime_int = 48;
const PAGE_SIZE: comptime_int = 4096;
const PAGE_CONTENT_SIZE: comptime_int = 4080;
const PAGE_LEAF_CAPACITY: comptime_int = 102;
const PAGE_NODE_CAPACITY: comptime_int = 85;

const LeafParseError = error {
  DelimiterNotFound,
};

pub const Leaf = packed struct {
  timestamp_bytes: [8]u8,
  value: [32]u8,

  fn get_timestamp(self: *const Leaf) u64 {
    return std.mem.readIntLittle(u64, &self.timestamp_bytes);
  }

  // fn leq(self: *const Leaf, other: *const Leaf) bool {
  //   if (self.timestamp() < other.timestamp()) {
  //     return true;
  //   } else if (self.timestamp() == other.timestamp()) {
  //       var i: u8 = 0;
  //       while (i < 32) : (i += 1) {
  //         if (a[i] < b[i]) {
  //           return true;
  //         } else if (a[i] > b[i]) {
  //           return false;
  //         }
  //       }

  //       return true;
  //   } else {
  //     return false;
  //   }
  // }

  fn parse(input: []const u8) !Leaf {
    const index = std.mem.indexOf(u8, input, ":");
    if (index == null) {
      return LeafParseError.DelimiterNotFound;
    } else {
      const leaf = Leaf{};
      leaf.value = utils.parse_hash(input[index..input.len]);
      const t = try std.fmt.parseUnsigned(u64, input[0..index], 10);
      std.mem.writeIntLittle(u64, t, &leaf.timestamp_bytes);
      return leaf;
    }
  }
};

// test "test leaf comparison" {
//   const a = try Leaf.parse("1:00");
//   const b = try Leaf.parse("3:00");
//   const c = try Leaf.parse("3:01");

//   try expect(Leaf.leq(a, b) == true);
//   try expect(Leaf.leq(b, a) == false);
//   try expect(Leaf.leq(b, c) == true);
//   try expect(Leaf.leq(c, b) == false);
//   try expect(Leaf.leq(a, a) == true);
//   try expect(Leaf.leq(b, b) == true);
//   try expect(Leaf.leq(b, b) == true);
// }

const TERMINAL_LEAF = Leaf {
  .value = utils.ZERO_HASH,
  .timestamp_bytes = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
};

const Node = packed struct {
  page_id_bytes: [4]u8,
  hash: [32]u8,
  leaf_timestamp_bytes: [8]u8,
  leaf_value_prefix: [4]u8,

  fn get_page_id(self: *const Node) u32 {
    return std.mem.readIntLittle(u32, &self.page_id_bytes);
  }

  fn get_leaf_timestamp(self: *const Node) u64 {
    return std.mem.readIntLittle(u64, &self.leaf_timestamp_bytes);
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

  fn leaf_content(self: *const Page) []Leaf {
    return @bitCast([PAGE_LEAF_CAPACITY]Leaf, self.content)[0..self.count];
  }

  fn node_content(self: *const Page) []Node {
    return @bitCast([PAGE_NODE_CAPACITY]Node, self.content)[0..self.count];
  }

  fn leaf_scan(self: *const Page, target: *const Leaf, digest: *Sha256) u8 {
    const a = target.timestamp();
    const v = target.value[0..32];
    for (self.leaf_content()) |leaf, i| {
      const b = target.timestamp();
      if ((a < b) or ((a == b) and std.mem.lessThan(u8, v, leaf.value[0..32]))) {
        return @intCast(u8, i);
      } else {
        digest.update(leaf.value[0..32]);
      }
    }

    return self.count;
  }

  // fn node_scan(self: *const Page, target: *const Leaf, digest: *Sha256) u8 {
  //   for (self.node_content()) |node, i| {
  //     if (target.leq(node.leaf)) {
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

const TOMBSTONE_CAPACITY: comptime_int = 496;

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
  padding: [2048]u8,

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
  page_id: u32,
  page: *Page,
  content_buffer: *[PAGE_CONTENT_SIZE]u8,

  // splice_buffer: *[PAGE_CONTENT_SIZE]u8,

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

    tree.page_id = 0;
    tree.page = try allocator.create(Page);
    tree.content_buffer = try allocator.create([PAGE_CONTENT_SIZE]u8);

    // tree.splice_buffer = try allocator.create([PAGE_CONTENT_SIZE]u8);

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

    // tree.splice_buffer = try allocator.create([PAGE_CONTENT_SIZE]u8);

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
    
    // allocator.destroy(self.splice_buffer);
    
    allocator.destroy(self);
  }

  // pub fn insert(self: *Tree, leaf: *const Leaf) !void {
  //   try self.insert_into_page(self.header.root_id, leaf, &self.header.root_hash);

  //   try self.flush_header();
  // }

  // fn insert_leaf(self: *Tree, page_id: u64, target: *const Leaf, page_hash: *[32]u8) !void {
  //   var digest = Sha256.init(.{});

  //   var target_page_id = page_id;
  //   var target_page = try self.open_page(page_id);
  //   assert(target_page.height == 0);

  //   const index = while (true) {
  //     const i = target_page.leaf_scan(target, &digest);
  //     if (i < target_page.count) {
  //       break i;
  //     } else {
  //       assert(target_page.next_id != 0);
  //       target_page_id = target_page.next_id;
  //       target_page = try self.open_page(target_page_id);
  //       assert(target_page.height == 0);
  //       continue;
  //     }
  //   }
  
  //   // now that we've found the place, we take different code paths
  //   // depending on whether the leaf is a split or not.
  //   if (self.is_split(target)) {

  //   } else {
  //     const values: *const [1]Leaf = target;
  //     const content = @bitCast([PAGE_LEAF_CAPACITY]Leaf, target_page.content);
  //     const buffer = self.leaf_buffer();
  //     const buffer_length = splice(Leaf, content, target_page.count, index, values, buffer);

  //     if (buffer_length == 0) {
  //       assert(target_page.next_id == 0);

  //     }
  //   }
  // }

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
    try self.file.seekTo(page_id * PAGE_SIZE);
    const bytes = @ptrCast(*[PAGE_SIZE]u8, self.page);
    const bytes_read = try self.file.readAll(bytes);
    assert(bytes_read == PAGE_SIZE);
    self.page_id = page_id;
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

  // fn leaf_buffer(self: *Tree) *[PAGE_LEAF_CAPACITY] {
  //   return @ptrCast(*[PAGE_LEAF_CAPACITY]Leaf, self.content_buffer)
  // }

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
        for (self.page.leaf_content()) |leaf| {
          const value = try utils.print_hash(leaf.value[0..32]);
          std.log.info("  0x{s} @ {d}", .{ value, leaf.get_timestamp() });
        }
      } else {
        assert(count <= PAGE_NODE_CAPACITY);
        for (self.page.node_content()) |node| {
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

