const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");

const Tree = @import("./tree.zig").Tree;
const utils = @import("./utils.zig");

/// A Scanner is the basic read interface to a tree.
/// Scanners are only initialize by calling tree.openScanner() on
/// an existing tree, NOT initialized directly.
/// .key is an internal [K]u8 array that holds the scanners *current location*,
/// .nodes is an ArrayList of *child nodes of the current key*,
/// .rootLevel stores the root level of the tree at transaction-time.
/// You can call scanner.seek(level, leaf) to page the given key's
/// children into .nodes. The rule for using .seek (which is enforced)
/// is that every key passed to .seek MUST be strictly greater than the
/// current key, ordered first by leaf comparison and second by reverse
/// level (lower levels are greater than higher levels).
/// It's important to close scanners in a timely manner.
pub fn Scanner(comptime X: usize, comptime Q: u8) type {
  return struct {
    pub const T = Tree(X, Q);
    pub const K = 2 + X;
    pub const V = 32;

    const Error = error { InvalidLevel, Rewind };

    txn: lmdb.Transaction(K, V),
    cursor: lmdb.Cursor(K, V),
    rootLevel: u16,
    key: T.Key,
    nodes: std.ArrayList(T.Node),

    pub fn init(self: *Scanner(X, Q), allocator: std.mem.Allocator, tree: *const T) !void {
      self.txn = try lmdb.Transaction(K, V).open(tree.env, true);
      self.cursor = try lmdb.Cursor(K, V).open(self.txn, tree.dbi);
      self.nodes = std.ArrayList(T.Node).init(allocator);
      self.rootLevel = tree.rootLevel;
      self.key = T.createKey(self.rootLevel, null);
    }

    pub fn seek(self: *Scanner(X, Q), level: u16, leaf: *const T.Leaf) !void {
      if (level == 0) return Error.InvalidLevel;

      if (T.lessThan(leaf, T.getLeaf(&self.key))) {
        return Error.Rewind;
      } else if (std.mem.eql(u8, leaf, T.getLeaf(&self.key)) and T.getLevel(&self.key) < level) {
        return Error.Rewind;
      }

      try self.nodes.resize(0);

      self.key = T.createKey(level - 1, leaf);
      try self.cursor.goToKey(&self.key);
      try self.append(&self.key, try self.cursor.getCurrentValue());

      while (try self.cursor.goToNext()) |key| {
        const value = try self.cursor.getCurrentValue();
        if (T.getLevel(key) != level - 1) break;
        if (T.isSplit(value)) break;
        try self.append(key, value);
      }
    }

    fn append(self: *Scanner(X, Q), key: *const [K]u8, value: *const [V]u8) !void {
      try self.nodes.append(.{ .key = key.*, .value = value.* });
    }

    pub fn close(self: *Scanner(X, Q)) void {
      self.nodes.deinit();
      self.cursor.close();
      self.txn.abort();
    }
  };
}

test "scanner" {
  const X = 6;
  const Q = 0x42;
  const T = Tree(X, Q);
  const allocator = std.heap.c_allocator;

  var tmp = std.testing.tmpDir(.{});
  const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
  defer allocator.free(path);

  var tree: T = undefined;
  try tree.init(allocator, path, .{ });
  defer tree.close();

  var leaf = [_]u8{ 0 } ** X;
  var hash: [32]u8 = undefined;
  const permutation = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9};
  for (permutation) |i| {
    std.mem.writeIntBig(u16, leaf[(X-2)..X], i + 1);
    Sha256.hash(&leaf, &hash, .{});
    try tree.insert(&leaf, &hash);
  }

  var scanner: Scanner(X, Q) = undefined;
  try scanner.init(allocator, &tree);
  defer scanner.close();

  std.mem.set(u8, &leaf, 0);
  try scanner.seek(scanner.rootLevel, &leaf);

  try expectEqualSlices(T.Node, &[_]T.Node{
    .{
      .key = T.parseKey("2:000000000000"),
      .value = utils.parseHash("8c0f5c019987df13c9db17498afbeed5a98cdabbd0619ae7d1407e0ea47505aa"),
    },
    .{
      .key = T.parseKey("2:000000000003"),
      .value = utils.parseHash("fa4530d6ce61a2a493e37083f018aa1beb835dd2661f921f201bd870eeee38ec"),
    },
    .{
      .key = T.parseKey("2:000000000005"),
      .value = utils.parseHash("fa23b8df5a4ddb651f3997f8ee9e7766356fc3eb3fd6b283ccebd666e803a51b"),
    },
  }, scanner.nodes.items);

  try scanner.seek(2, &[_]u8{ 0, 0, 0, 0, 0, 5 });
  try expectEqualSlices(T.Node, &[_]T.Node{
    .{
      .key = T.parseKey("1:000000000005"),
      .value = utils.parseHash("1ed43d22ab1f8714a58e57d25455350c2ea48b2a7d51c20d8ee48a1e7b4ae29e"),
    },
    .{
      .key = T.parseKey("1:000000000008"),
      .value = utils.parseHash("c8e441d5955c26d76b3cf2202cad48028a4f3a097d50db8810a71a34a69bdedd"),
    },
    .{
      .key = T.parseKey("1:000000000009"),
      .value = utils.parseHash("4cd0b46302810af02c86bad8ed6ebf13ead97ee3830b7fdd968307fd2647de76"),
    },
  }, scanner.nodes.items);

  try scanner.seek(1, &[_]u8{ 0, 0, 0, 0, 0, 8 });

  try expectEqualSlices(T.Node, &[_]T.Node{
    .{
      .key = T.parseKey("0:000000000008"),
      .value = utils.parseHash("33935bd20b29e71c259688628b274310649244541a297726019eb69c5c4b7c57"),
    },
  }, scanner.nodes.items);

  try expectError(Scanner(X, Q).Error.Rewind, scanner.seek(1, &[_]u8{ 0, 0, 0, 0, 0, 5 }));

  tmp.cleanup();
}