const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const hex = std.fmt.fmtSliceHexLower;

const Environment = @import("./lmdb/environment.zig").Environment;
const Transaction = @import("./lmdb/transaction.zig").Transaction;
const Cursor = @import("./lmdb/cursor.zig").Cursor;

const Tree = @import("./tree.zig").Tree;
const utils = @import("./utils.zig");

const allocator = std.heap.c_allocator;

pub fn Scanner(comptime X: usize, comptime Q: u8) type {
  return struct {
    pub const T = Tree(X, Q);
    pub const K = 2 + X;
    pub const V = 32;

    const Error = error {
      InvalidLevel,
      Rewind,
    };

    txn: Transaction(K, V),
    cursor: Cursor(K, V),
    key: T.Key,
    nodes: std.ArrayList(T.Node),

    pub fn seek(self: *Scanner(X, Q), level: u16, leaf: *const T.Leaf) !void {
      if (level == 0) {
        return Error.InvalidLevel;
      }

      if (T.lessThan(leaf, T.getLeaf(&self.key))) {
        return Error.Rewind;
      } else if (level < T.getLevel(&self.key)) {
        return Error.Rewind;
      }

      try self.nodes.resize(0);

      self.key = T.createKey(level - 1, leaf);
      var child = try self.cursor.goToKey(&self.key);
      var childValue = self.cursor.getCurrentValue().?;
      while (child) |childKey| {
        if (T.getLevel(childKey) != level - 1) break;

        try self.nodes.append(.{
          .key = childKey.*,
          .value = childValue.*,
        });

        child = try self.cursor.goToNext();
        childValue = self.cursor.getCurrentValue().?;
        if (T.isSplit(childValue)) break;
      }
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

  var tmp = std.testing.tmpDir(.{});
  const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
  defer allocator.free(path);

  var tree = try T.open(path, .{ });
  defer tree.close();

  var key = [_]u8{ 0 } ** X;
  var value: [32]u8 = undefined;
  const permutation = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9};
  for (permutation) |i| {
    std.mem.writeIntBig(u16, key[(X-2)..X], i + 1);
    Sha256.hash(&key, &value, .{});
    try tree.insert(&key, &value);
  }

  var scanner = try tree.openScanner();
  defer scanner.close();

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