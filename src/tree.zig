const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Store = @import("./store.zig").Store;
const Header = @import("./header.zig").Header;
const Page = @import("./page.zig").Page;
const Node = @import("./node.zig").Node;
const Leaf = @import("./leaf.zig").Leaf;

const constants = @import("./constants.zig");
const utils = @import("./utils.zig");

const allocator = std.heap.c_allocator;

pub const TERMINAL_LEAF = Leaf {
  .value = constants.ZERO_HASH,
  .timestamp_bytes = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
};

const NodeList = std.ArrayList(Node);

pub const Tree = struct {
  pub const Error = std.mem.Allocator.Error || Store.Error;

  store: Store,
  header: *Header,
  content_buffer: *[constants.PAGE_CONTENT_SIZE]u8,
  splice: NodeList,

  pub fn open(path: ?[]const u8) Error!Tree {
    var store = try Store.open(allocator, path);
    const header_page = try store.get(0);
    const header = @ptrCast(*Header, header_page);

    if (store.created()) {
      header.init();
      const root_id = 1;
      const root_page = try store.get(root_id);
      const root = @ptrCast(*Page, root_page);
      root.set_meta(0x0000);
      root.level = 0;
      root.count = 1;
      root.leaf_content()[0] = TERMINAL_LEAF;
      root.set_next_id(0);

      header.set_root_id(root_id);
      header.set_leaf_count(1);
      header.set_page_count(1);
      header.set_height(1);
      Sha256.hash(TERMINAL_LEAF.value[0..32], &header.root_hash, .{});
    } else {
      assert(std.mem.eql(u8, &header.magic, &constants.MAGIC));
    }

    const content_buffer = try allocator.create([constants.PAGE_CONTENT_SIZE]u8);

    return Tree{
      .store = store,
      .header = header,
      .content_buffer = content_buffer,
      .splice = NodeList.init(allocator),
    };
  }

  pub fn close(self: *Tree) void {
    self.store.close();
    self.splice.deinit();
    allocator.destroy(self.content_buffer);
  }

  fn get(self: *Tree, id: u32) Store.Error!*Page {
    assert(id > 0);
    assert(id <= self.header.get_page_count());
    const page = try self.store.get(id);
    return @ptrCast(*Page, page);
  }

  fn get_new_page_id(self: *Tree) u32 {
    const tombstone = self.header.pop_tombstone();
    if (tombstone == 0) {
      const id = self.header.get_page_count() + 1;
      self.header.set_page_count(id);
      return id;
    } else {
      return tombstone;
    }
  }

  fn is_split(self: *const Tree, leaf: *const Leaf) bool {
    return leaf.value[0] < self.header.fanout_threshhold;
  }

  fn create_page(self: *Tree, id: u32, level: u8, count: u8, next_id: u32) Store.Error!*Page {
    const page = try self.get(id);
    page.set_meta(0x0000);
    page.level = level;
    page.count = count;
    page.set_next_id(next_id);
    return page;
  }

  fn copy_page(self: *Tree, new_id: u32, old_id: u32) Store.Error!*Page {
    assert(old_id > 0);
    assert(new_id > 0);

    self.header.push_tombstone(old_id);

    const old_page = try self.get(old_id);
    const new_page = try self.get(new_id);
    old_page.set_meta(constants.TOMBSTONE);
    new_page.set_meta(0x0000);
    new_page.level = old_page.level;
    new_page.count = old_page.count;

    if (new_page.level == 0) {
      const old_content = old_page.leaf_content();
      const new_content = new_page.leaf_content();
      std.mem.copy(Leaf, new_content[0..new_page.count], old_content[0..old_page.count]);
    } else {
      const old_content = old_page.node_content();
      const new_content = new_page.node_content();
      std.mem.copy(Node, new_content[0..new_page.count], old_content[0..old_page.count]);
    }

    new_page.next_id_bytes = old_page.next_id_bytes;

    return new_page;
  }

  // found it easier to write this recursively than with loops since
  // there are essentially two separate base cases.
  fn shift_list(
    self: *Tree,
    comptime T: type,
    level: u8,
    head_id: u32,
    tail_length: u8,
    next_id: u32,
    digest: *Sha256,
  ) Store.Error!void {
    const capacity = @divExact(constants.PAGE_CONTENT_SIZE, @sizeOf(T));
    const buffer = @ptrCast(*[capacity]T, self.content_buffer);

    if (next_id == 0) {
      const page = try self.create_page(head_id, level, tail_length, 0);
      const content = @ptrCast(*[capacity]T, &page.content);
      std.mem.copy(Leaf, content, buffer[0..tail_length]);

      for (content[0..page.count]) |leaf| {
        digest.update(&leaf.value);
      }
    } else {
      const page = try self.copy_page(head_id, next_id);
      const content = @ptrCast(*[capacity]T, &page.content);
      if (page.count + tail_length <= capacity) {
        assert(page.get_next_id() == 0);
        std.mem.copyBackwards(T, content[tail_length..tail_length+page.count], content[0..page.count]);
        std.mem.copy(T, content[0..tail_length], buffer[0..tail_length]);
        page.count += tail_length;

        for (content[0..page.count]) |leaf| {
          digest.update(&leaf.value);
        }
      } else {
        const new_next_id = page.get_next_id();

        utils.swap(T, content, buffer);
        const remaining_capacity = capacity - tail_length;
        std.mem.copy(T, content[tail_length..capacity], buffer[0..remaining_capacity]);
        const new_tail_length = page.count - remaining_capacity;
        std.mem.copy(T, buffer[0..new_tail_length], buffer[remaining_capacity..page.count]);
        page.count = capacity;

        const tail_id = self.get_new_page_id();
        page.set_next_id(tail_id);
        
        for (content[0..page.count]) |leaf| {
          digest.update(&leaf.value);
        }
        
        try self.shift_list(T, level, tail_id, new_tail_length, new_next_id, digest);
      }
    }
  }

  pub fn insert(self: *Tree, leaf: *const Leaf) Error!void {
    const leaf_count = self.header.get_leaf_count();
    const height = self.header.get_height();

    const root = Node {
      .page_id_bytes = self.header.root_id_bytes,
      .hash = self.header.root_hash,
      .leaf_timestamp_bytes = TERMINAL_LEAF.timestamp_bytes,
      .leaf_value_prefix = [_]u8{ 0, 0, 0, 0 },
    };

    if (height > 1) {
      try self.insert_node(root, leaf, 0);
      @panic("not implemented");
    } else {
      try self.insert_leaf(root, leaf);
      if (self.splice.items.len == 1) {
        const node = self.splice.pop();
        self.header.root_id_bytes = node.page_id_bytes;
        self.header.root_hash = node.hash;
      } else if (self.splice.items.len == 2) {
        @panic("not implemented");
      } else {
        @panic("internal error: unexpected splice state after leaf insert");
      }
    }

    self.header.set_leaf_count(leaf_count + 1);
  }

  fn insert_leaf(self: *Tree, parent_node: Node, target: *const Leaf) Error!void {
    assert(self.splice.items.len == 0);

    var digest = Sha256.init(.{});

    const first_id = self.get_new_page_id();
    var page = try self.copy_page(first_id, parent_node.get_page_id());
    var target_index = page.leaf_scan(target, &digest);
    while (target_index == page.count) {
      const old_next_id = page.get_next_id();
      const new_next_id = self.get_new_page_id();
      page.set_next_id(new_next_id);
      page = try self.copy_page(new_next_id, old_next_id);
      target_index = page.leaf_scan(target, &digest);
    }

    digest.update(&target.value);

    const buffer = self.leaf_buffer();
    const content = page.leaf_content();
    const next_id = page.get_next_id();
    const capacity = constants.PAGE_LEAF_CAPACITY;

    if (self.is_split(target)) {
      var tail_length = page.count - target_index;
      page.count = target_index + 1;
      std.mem.copy(Leaf, buffer[0..tail_length], content[target_index..page.count]);
      content[target_index] = target.*;

      page.set_next_id(0);

      var first_node = target.derive_node(first_id);
      digest.final(&first_node.hash);

      digest = Sha256.init(.{});
      const second_id = self.get_new_page_id();
      try self.shift_list(Leaf, 0, second_id, tail_length, next_id, &digest);
      
      var second_node = parent_node.derive_node(second_id);
      digest.final(&second_node.hash);

      try self.splice.append(first_node);
      try self.splice.append(second_node);
    } else {
      if (page.count == capacity) {
        buffer[0] = content[capacity-1];
        std.mem.copyBackwards(Leaf, content[target_index+1..capacity], content[target_index..capacity-1]);
        content[target_index] = target.*;
        
        const tail_id = self.get_new_page_id();
        page.set_next_id(tail_id);

        for (content[target_index+1..capacity]) |leaf| {
          digest.update(&leaf.value);
        }

        try self.shift_list(Leaf, 0, tail_id, 1, next_id, &digest);
      } else {
        assert(next_id == 0);
        std.mem.copyBackwards(Leaf, content[target_index+1..page.count+1], content[target_index..page.count]);
        content[target_index] = target.*;
        page.count += 1;

        for (content[target_index+1..page.count]) |leaf| {
          digest.update(&leaf.value);
        }
      }

      var first_node = parent_node.derive_node(first_id);
      digest.final(&first_node.hash);
      try self.splice.append(first_node);
    }
  }

  fn insert_node(self: *Tree, parent_node: Node, target: *const Leaf, uncle_id: u32) Error!?u32 {
    assert(self.splice.items.len == 0);

    var digest = Sha256.init(.{});

    const first_id = self.get_new_page_id();
    var page = self.copy_page(first_id, parent_node.get_page_id());
    var target_index = page.node_scan(target, &digest);
    while (target_index == page.count) {
      const old_next_id = page.get_next_id();
      const new_next_id = self.get_new_page_id();
      page.set_next_id(new_next_id);
      page = try self.copy_page(new_next_id, old_next_id);
      target_index = page.node_scan(target, &digest);
    }

    const content = page.node_content();
    const target_node = content[target_index];

    const is_target_split = self.is_split(target_node);
    if (is_target_split) {
      assert(target_index == page.count - 1);
      assert(page.get_next_id() == 0);
      assert(parent_node.get_leaf_timestamp() == target_node.get_leaf_timestamp());
      assert(std.mem.eql(u8, parent_node.get_leaf_value_prefix(), target_node.get_leaf_value_prefix()));
    }

    var next_id = page.get_next_id();

    if (page.level > 1) {
      var sibling: u32 = 0;
      if (target_index < page.count - 1) {
        sibling = content[page.count-1].get_page_id();
      } else if (next_id != 0) {
        const next_page = self.get(next_id);
        const next_content = next_page.node_content();
        sibling = next_content[0].get_page_id();
      } else if (uncle_id != 0) {
        const uncle_page = self.get(uncle_id);
        const uncle_content = uncle_page.node_content();
        sibling = uncle_content[0].get_page_id();
      }

      const split = try self.insert_node(target_node, target, sibling);
    } else {
      try self.insert_leaf(target_node, target);
    }

    // alright - now we're left with a splice list that has one or more
    // (ie aritrarily more) nodes to replace target_node with.
    // *Any* of the nodes in the node slice might be a split.
  
    // If the target_node is itself a split, and none of the
    // splice nodes are splits, then we have to merge parent_node with its
    // next sibling at the level above. How and where should we do this?
    // 
    //                |-----------------|
    // 2              | |p| |q|         |
    //                |-----------------|
    //                 /       \
    //   |-----------------|  |-----------------|
    // 1 | |a| |b| |c|     |  | |x| |y|         |
    //   |-----------------|  |-----------------|
    // 
    // The situation would be parent_node = p and target_node = c,
    // and the splice returns a modified c' that isn't a split any more.
    // This means that p and q need to be merged into a single node terminated by y,
    // and their page lists have to be concatenated.

    // This isn't necessary on the leaf level because there, hashes *are* terminal
    // values (they're equivalent). You can tell up-front that the insert target will
    // fit inside a given leaf page, and ALSO that it won't change the split status of
    // the current page-ending leaf (since it's a leaf and leafs are immutable).
    // However at the node level, we might end up inserting INTO the current page-ending node,
    // changing its hash and split status, etc.

    // It would be nice to keep all the logic separated by levels, but this would be hard since
    // if we're here with parent_node = p, then we don't have access to q or its contents at all.
    // Instead I think we have to handle this in the calling function:
    // We return p's page ID, signaling that we have to merge with the node to the right.
    // Then in the caller (where target_node = p), we advance one step to q,
    // call a subroutine to concat the page lists, returning a new head id that replaces
    // both p and q (with q's terminal leaf data).
    // Of course this new node might or might not be a split itself.

    // What if q doesn't exist? This happens in the case where p is a split to begin with.
    // 
    //                |-----------------|
    // 3              | |u| |v|         |
    //                |-----------------|
    //                 /       \
    //   |-----------------|  |-----------------|
    // 2 | |p|             |  | |j| |k|         |
    //   |-----------------|  |-----------------|
    //      |                    |
    //   |-----------------|  |-----------------|
    // 1 | |a| |b| |c|     |  | |x| |y|         |
    //   |-----------------|  |-----------------|
    //
    // So here, if c -> c' and c' is no longer a split, we have to somehow locate x and y
    // and "steal" them in order to update p. We locate x and y by locating j.

    // We do this by passing the parent's successor at the parent layer *even if it's
    // across several node splits*. So when we insert into u, we pass v as an argument.
    // Then when we insert into p, we look for the next sibling and realize that it doesn't exist
    // (since p is a split), so we descend *from v* (the parent's sibling that we're given) to get j,
    // and pass that. Then inside level 1, when we realize that c -> c' and c' is not a split,
    // and we want to merge with the next node, we descend from j to get x and y etc.

    // So then how do we build back up once we've eliminated j by merging on L1?
    // 
    
    
    // This could mean going arbitrarily far up the tree, so maybe
    // it's best to try to store sibling links inside each page? How hard would that be?
    // We could do it by setting the second meta byte to be "this is the end of the list"
    // and using the next_id to point to the head of the next conceptual node at that level.
    // But this won't work: immutability/copy-on-write completely rules out horizontal linking
    // since every single node on a given level would have to be updated.
    // So we have no choice but to do tree traversal (probably a little simpler anyway).

    // 

    // It's important to have abstractions to treat page lists like atomic nodes.
    // Can't be messing around with list logic when trying to do splits and merges.

    // insert the target leaf into the target node
    if (page.level > 1) {
      // const split = try self.insert_node(target_node, target);
      // if (split) |id| {
      //   // this means we have to merge the target_node with its right sibling.
      //   // if no right sibling exists (ie target_node is the last node in the page)
      //   // then we pass the id back up to *our* caller, etc.
      // } else {
      //
      // }
    } else {
      try self.insert_leaf(target_node, target);
      // Cool! We have either one or two nodes in the splice buffer,
      // either of which could be splits. Should we just do exhaustive case analysis?
      if (self.splice.items.len == 1) {
        const node = self.splice.pop();
        if (self.is_split(node)) {
          digest.update(&node.hash);
          const first_node = node.derive_node(first_id);
          digest.final(&first_node.hash);
          self.splice.push(first_node);

          // there's only another node if target_node wasn't the last node in parent_node!
          if (is_target_split) {
            return;
          } else {
            // there are more nodes between target_node and parent_node's terminal leaf
            const second_id = self.get_new_page_id();
            const second_node = parent_node.derive_node(second_id);
            var next_id = page.get_next_id();
            if (target_index == PAGE_NODE_CAPACITY - 1) {
              assert(next_id != 0);
              page = self.get(next_id);

            }
            self.splice.push(second_node);
          }
        } else {

        }
      } else if (self.splice.items.len == 2) {
        const second_node = self.splice.pop();
        const first_node = self.splice.pop();
        const first_split = self.is_split(first_node);
        const second_split = self.is_split(second_node);
        if (first_split and second_split) {

        } else if (first_split and !second_split) {

        } else if (!first_split and second_split) {
          
        } else if (!first_split and !second_split) {

        }
      } else {
        @panic("internal error: unexpected splice state after leaf insert");
      }
    }
  }

  fn node_buffer(self: *Tree) *[constants.PAGE_NODE_CAPACITY]Node {
    return @ptrCast(*[constants.PAGE_NODE_CAPACITY]Node, self.content_buffer);
  }

  fn leaf_buffer(self: *Tree) *[constants.PAGE_LEAF_CAPACITY]Leaf {
    return @ptrCast(*[constants.PAGE_LEAF_CAPACITY]Leaf, self.content_buffer);
  }

  pub fn print_pages(self: *Tree) !void {
    std.log.info("HEADER ---------------------------", .{});
    std.log.info("  magic: 0x{s}", .{ utils.print_hash(&self.header.magic) });
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
    
    var id: u32 = 1;
    while (id <= self.header.get_page_count()) : (id += 1) {
      const page = try self.get(id);
      if (page.get_meta() == constants.TOMBSTONE) {
        std.log.info("PAGE {d} (deleted)", .{ id });
        continue;
      }

      const count = page.count;
      std.log.info("PAGE {d} | level {d} | {d} cells", .{ id, page.level, count });
      if (page.level == 0) {
        assert(count <= constants.PAGE_LEAF_CAPACITY);
        for (page.leafs()) |leaf| {
          const value = try utils.print_hash(&leaf.value);
          std.log.info("  0x{s} @ {d}", .{ value, leaf.get_timestamp() });
        }
      } else {
        assert(count <= constants.PAGE_NODE_CAPACITY);
        for (page.nodes()) |node| {
          const hash = try utils.print_hash(&node.hash);
          const value = try utils.print_hash(&node.leaf_value_prefix);
          std.log.info("  0x{s} -> {d} ({d}:{s}...)", .{ hash, node.get_page_id(), node.get_leaf_timestamp(), value });
        }
      }

      const next_id = page.get_next_id();
      if (next_id > 0) {
        std.log.info("CONTINUED IN PAGE {d}", .{ next_id });
      }

      std.log.info("END OF PAGE {d}", .{ id });
    }
  }
};

test "insert leaves into a single page" {
  const a = try Leaf.parse("01:ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb");
  const b = try Leaf.parse("02:3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d");
  const c = try Leaf.parse("03:2e7d2c03a9507ae265ecf5b5356885a53393a2029d241394997265a1a25aefc6");

  const z = try Leaf.parse("18446744073709551615:00");

  var tree = try Tree.open(null);

  try tree.insert(&b);
  try tree.insert(&a);
  try tree.insert(&c);

  // try expect(tree.header.get_page_count() == 1);
  try expect(tree.header.get_leaf_count() == 4);

  const root = try tree.get(tree.header.get_root_id());
  try expect(root.eql(&Page.create(Leaf, 0, &[_]Leaf{a, b, c, z}, 0)));

  tree.close();
}

test "insert leaves into a list of pages" {
  var tree = try Tree.open(null);

  const a = try Leaf.parse("01:ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb");
  const b = try Leaf.parse("02:3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d");
  const c = try Leaf.parse("03:2e7d2c03a9507ae265ecf5b5356885a53393a2029d241394997265a1a25aefc6");
  const d = try Leaf.parse("04:18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4");
  const e = try Leaf.parse("05:3f79bb7b435b05321651daefd374cdc681dc06faa65e374e38337b88ca046dea");
  const f = try Leaf.parse("06:252f10c83610ebca1a059c0bae8255eba2f95be4d1d7bcfa89d7248a82d9f111");
  const g = try Leaf.parse("07:cd0aa9856147b6c5b4ff2b7dfee5da20aa38253099ef1b4a64aced233c9afe29");
  const h = try Leaf.parse("08:aaa9402664f1a41f40ebbc52c9993eb66aeb366602958fdfaa283b71e64db123");
  const i = try Leaf.parse("09:de7d1b721a1e0632b7cf04edf5032c8ecffa9f9a08492152b926f1a5a7e765d7");
  const j = try Leaf.parse("10:189f40034be7a199f1fa9891668ee3ab6049f82d38c68be70f596eab2e1857b7");
  const k = try Leaf.parse("11:8254c329a92850f6d539dd376f4816ee2764517da5e0235514af433164480d7a");
  const l = try Leaf.parse("12:acac86c0e609ca906f632b0e2dacccb2b77d22b0621f20ebece1a4835b93f6f0");
  const m = try Leaf.parse("13:62c66a7a5dd70c3146618063c344e531e6d4b59e379808443ce962b3abd63c5a");

  const z = try Leaf.parse("18446744073709551615:00");

  try tree.insert(&e);
  try tree.insert(&c);
  try tree.insert(&m);
  try tree.insert(&g);
  try tree.insert(&b);
  try tree.insert(&f);
  try tree.insert(&k);
  try tree.insert(&d);
  try tree.insert(&h);
  try tree.insert(&a);
  try tree.insert(&j);
  try tree.insert(&l);
  try tree.insert(&i);
  
  // try expect(tree.header.get_page_count() == 3);
  try expect(tree.header.get_leaf_count() == 14);

  const content =  &[_]Leaf{ a, b, c, d, e, f, g, h, i, j, k, l, m, z };
  const root = try tree.get(tree.header.get_root_id());
  try expect(root.eql(&Page.create(Leaf, 0, content, 0)));

  tree.close();
}