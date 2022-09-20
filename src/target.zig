const std = @import("std");

const lmdb = @import("lmdb");
const okra = @import("./lib.zig");

pub fn Target(comptime X: usize, comptime Q: u8) type {
  return struct {
    const K = 2 + X;
    const V = 32;

    const Env = lmdb.Environment(K, V);
    const Txn = lmdb.Transaction(K, V);
    const Cursor = lmdb.Cursor(K, V);
    const Node = okra.Node(X);
    const Tree = okra.Tree(X, Q);
    const Source = okra.Source(X, Q);

    pub const Error = error { Conflict, InvalidDatabase };

    tree: *Tree,
    txn: Txn,
    cursor: Cursor,
    rootLevel: u16,
    keys: [][K]u8,
    allocator: std.mem.Allocator,

    pub fn init(self: *Target(X, Q), allocator: std.mem.Allocator, tree: *Tree) !void {
      self.tree = tree;
      self.txn = try Txn.open(tree.env, true);
      self.cursor = try Cursor.open(self.txn, tree.dbi);
      if (try self.cursor.goToLast()) |key| {
        const level = Tree.getLevel(key);
        if (Tree.isKeyLeftEdge(key) and level > 0) {
          self.rootLevel = level;
        } else {
          return Error.InvalidDatabase;
        }
      } else {
        return Error.InvalidDatabase;
      }

      self.allocator = allocator;
      self.keys = try allocator.alloc([K]u8, self.rootLevel);
      for (self.keys) |*key, i| {
        Tree.setLevel(key, @intCast(u16, i));
        Tree.setLeaf(key, null);
      }
    }

    pub fn seek(self: *Target(X, Q), targetRootKey: *Tree.Key, sourceRoot: *const Tree.Leaf) !void {
      const level = Tree.getLevel(targetRootKey);

      try self.cursor.goToKey(targetRootKey);

      if (!std.mem.eql(u8, sourceRoot, Tree.getLeaf(targetRootKey))) {
        while (try self.cursor.goToNext()) |next| {
          if (Tree.getLevel(next) != level) break;
          if (Tree.lessThan(sourceRoot, Tree.getLeaf(next))) {
            break;
          } else {
            std.mem.copy(u8, targetRootKey, next);
          }
        }

        try self.cursor.goToKey(targetRootKey);
      }
    }

    // pub fn seek(self: *Target(X, Q), level: u16, targetRoot: ?*const Tree.Leaf, sourceRoot: *const Tree.Leaf) !void {
    //   const targetRootKey = &self.keys[level];
    //   Tree.setLeaf(targetRootKey, targetRoot);

    //   try self.cursor.goToKey(targetRootKey);

    //   if (!std.mem.eql(u8, sourceRoot, Tree.getLeaf(targetRootKey))) {
    //     while (try self.cursor.goToNext()) |next| {
    //       if (Tree.getLevel(next) != level) break;
    //       if (Tree.lessThan(sourceRoot, Tree.getLeaf(next))) {
    //         break;
    //       } else {
    //         std.mem.copy(u8, targetRootKey, next);
    //       }
    //     }

    //     try self.cursor.goToKey(targetRootKey);
    //   }
    // }

    pub fn collect(self: *Target(X, Q), nodes: []Node, leaves: *std.ArrayList(Node)) !void {
      var key = Tree.createKey(0, null);
      for (nodes) |node| {
        std.mem.copy(u8, key[2..], &node.leaf);
        if (try self.txn.get(self.tree.dbi, &key)) |value| {
          if (!std.mem.eql(u8, value, &node.hash)) {
            return Error.Conflict;
          }
        } else {
          try leaves.append(.{ .leaf = node.leaf, .hash = node.hash });
        }
      }
    }

    pub fn close(self: *Target(X, Q)) void {
      self.allocator.free(self.keys);
      self.cursor.close();
      self.txn.abort();
    }
  };
}
