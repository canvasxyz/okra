const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("./lmdb/lmdb.zig").lmdb;
const Environment = @import("./lmdb/environment.zig").Environment;
const Transaction = @import("./lmdb/transaction.zig").Transaction;
const Cursor = @import("./lmdb/cursor.zig").Cursor;

const allocator = std.heap.c_allocator;

const InsertResult = enum { delete, update };

const Options = struct {
  log: ?std.fs.File.Writer = null,
  mapSize: usize = 10485760,
};

pub fn Tree(comptime X: usize, comptime Q: u8) type {
  const K = 2 + X;
  const V = 32;

  return struct {
    pub const Error = error {
      KeyNotFound,
    } || Transaction(K, V).Error || Cursor(K, V).Error || std.mem.Allocator.Error || std.os.WriteError;

    pub const Leaf = [X]u8;
    pub const Key = [K]u8;
    pub const Value = [V]u8;
    pub const Node = struct {
      key: [K]u8,
      value: [V]u8,
    };

    env: Environment(K, V),
    dbi: lmdb.MDB_dbi,

    root: [K]u8,
    parentValue: [V]u8,
    newChildren: std.ArrayList(Node),

    log: ?std.fs.File.Writer,
    prefix: std.ArrayList(u8),

    pub fn open(path: []const u8, options: Options) !*Tree(X, Q) {
      const tree = try allocator.create(Tree(X, Q));
      errdefer allocator.destroy(tree);

      tree.log = options.log;
      tree.newChildren = std.ArrayList(Node).init(allocator);
      tree.prefix = std.ArrayList(u8).init(allocator);

      tree.env = try Environment(K, V).open(path, .{ .mapSize = options.mapSize });
      var txn = try Transaction(K, V).open(tree.env, false);
      errdefer txn.abort();

      tree.dbi = try txn.openDbi();
      var cursor = try Cursor(K, V).open(txn, tree.dbi);
      errdefer cursor.close();

      if (try cursor.goToLast()) |root| {
        std.mem.copy(u8, &tree.root, root);
        assert(isKeyLeftEdge(&tree.root));
        assert(getLevel(&tree.root) > 0);
      } else {
        std.mem.set(u8, &tree.root, 0);
        var value: Value = [_]u8{ 0 } ** V;
        try tree.set(&txn, &tree.root, &value);
        Sha256.hash(&[_]u8{}, &value, .{});
        setLevel(&tree.root, 1);
        try tree.set(&txn, &tree.root, &value);
      }

      try txn.commit();
      return tree;
    }

    pub fn close(self: *Tree(X, Q)) void {
      self.env.close();
      self.newChildren.deinit();
      allocator.destroy(self);
    }

    pub fn insert(self: *Tree(X, Q), leaf: *const Leaf, value: *const [V]u8) Error!void {
      if (self.log) |log| {
        try log.print("insert({s}, {s})\n", .{ hex(leaf), hex(value) });
        try log.print("root {s}\n", .{ printKey(&self.root) });
        try self.prefix.resize(0);
        try self.prefix.append('|');
        try self.prefix.append(' ');
      }

      var level = getLevel(&self.root);

      var txn = try Transaction(K, V).open(self.env, false);
      var cursor = try Cursor(K, V).open(txn, self.dbi);

      const firstChild = getChild(&self.root);
      const result = switch (level) {
        0 => @panic("internal error - root key has level zero"),
        1 => try self.insertLeaf(&txn, &cursor, &firstChild, leaf, value),
        else => try self.insertNode(&txn, &cursor, &firstChild, leaf, value, true),
      };

      assert(result == InsertResult.update);

      if (self.log) |log| {
        try self.prefix.resize(0);
        try log.print("new root {s} -> {s}\n", .{ printKey(&self.root), hex(&self.parentValue) });
        try log.print("newChildren: {d}\n", .{ self.newChildren.items.len });
        for (self.newChildren.items) |node|
          try log.print("- {s} -> {s}\n", .{ printKey(&node.key), hex(&node.value) });
      }

      var newChildrenCount = self.newChildren.items.len;
      while (newChildrenCount > 0) : (newChildrenCount = self.newChildren.items.len) {
        try self.set(&txn, &self.root, &self.parentValue);
        for (self.newChildren.items) |node| try self.set(&txn, &node.key, &node.value);

        try self.hashRange(&cursor, &self.root, &self.parentValue);

        level += 1;
        setLevel(&self.root, level);

        for (self.newChildren.items) |newChild| {
          if (isSplit(&newChild.value)) {
            var node = Node{ .key = getParent(&newChild.key), .value = undefined };
            try self.hashRange(&cursor, &newChild.key, &node.value);
            try self.newChildren.append(node);
          }
        }

        try self.newChildren.replaceRange(0, newChildrenCount, &.{});
        if (self.log) |log| {
          try log.print("new root {s} -> {s}\n", .{ printKey(&self.root), hex(&self.parentValue) });
          try log.print("newChildren: {d}\n", .{ self.newChildren.items.len });
          for (self.newChildren.items) |node|
            try log.print("- {s} -> {s}\n", .{ printKey(&node.key), hex(&node.value) });
        }
      }

      try self.set(&txn, &self.root, &self.parentValue);

      if (try cursor.goToLast()) |lastKey| {
        if (self.log) |log| try log.print("last key: {s}\n", .{ printKey(lastKey) });
      } else {
        @panic("internal error: cursor.goToLast() returned null");
      }

      while (try cursor.goToPrevious()) |previousKey| {
        if (isKeyLeftEdge(previousKey)) {
          const newRoot = createKey(getLevel(previousKey), getLeaf(previousKey));
          try self.delete(&txn, &self.root);
          std.mem.copy(u8, &self.root, &newRoot);
          if (self.log) |log| try log.print("replaced root key: {s}\n", .{ printKey(&self.root) });
        } else {
          break;
        }
      }

      cursor.close();
      try txn.commit();
    }

    fn insertLeaf(
      self: *Tree(X, Q),
      txn: *Transaction(K, V),
      cursor: *Cursor(K, V),
      firstChild: *const Key,
      leaf: *const Leaf,
      value: *const Value,
    ) Error!InsertResult {
      if (self.log) |log| {
        try log.print("{s}insertLeaf\n", .{ self.prefix.items });
        try log.print("{s}firstChild {s}\n", .{ self.prefix.items, printKey(firstChild) });
      }

      assert(getLevel(firstChild) == 0);
      assert(lessThan(getLeaf(firstChild), leaf));

      const key = createKey(0, leaf);
      try self.set(txn, &key, value);
      try self.hashRange(cursor, firstChild, &self.parentValue);

      if (isSplit(value)) {
        var node = Node{ .key = getParent(&key), .value = undefined };
        try self.hashRange(cursor, &key, &node.value);
        try self.newChildren.append(node);
      }

      return InsertResult.update;
    }

    fn insertNode(
      self: *Tree(X, Q),
      txn: *Transaction(K, V),
      cursor: *Cursor(K, V),
      firstChild: *const Key,
      leaf: *const Leaf,
      value: *const Value,
      isLeftEdge: bool,
    ) Error!InsertResult {
      if (self.log) |log| {
        try log.print("{s}insertNode\n", .{ self.prefix.items });
        try log.print("{s}firstChild {s}\n", .{ self.prefix.items, printKey(firstChild) });
      }

      const level = getLevel(firstChild);
      assert(level > 0);
      assert(lessThan(getLeaf(firstChild), leaf));

      const targetKey = try self.findTargetKey(cursor, firstChild, leaf);
      if (self.log) |log| try log.print("{s}targetKey  {s}\n", .{ self.prefix.items, printKey(&targetKey) });

      const isFirstChild = std.mem.eql(u8, &targetKey, firstChild);
      if (self.log) |log| try log.print("{s}isFirstChild {d}\n", .{ self.prefix.items, isFirstChild });

      const depth = self.prefix.items.len;
      if (self.log != null) {
        try self.prefix.append('|');
        try self.prefix.append(' ');
      }

      const result = switch (level) {
        1 => try self.insertLeaf(txn, cursor, &getChild(&targetKey), leaf, value),
        else => try self.insertNode(txn, cursor, &getChild(&targetKey), leaf, value, isLeftEdge and isFirstChild),
      };

      if (self.log) |log| {
        try self.prefix.resize(depth);
        switch (result) {
          InsertResult.delete => try log.print("{s}result: delete\n", .{ self.prefix.items }),
          InsertResult.update => try log.print("{s}result: update\n", .{ self.prefix.items }),
        }
      }

      const oldChildrenCount = self.newChildren.items.len;

      var parentResult: InsertResult = undefined;

      switch (result) {
        InsertResult.delete => {
          assert(isLeftEdge == false or isFirstChild == false);

          const previousChild = try self.goToPreviousChild(txn, cursor, &targetKey);
          const previousGrandChild = getChild(&previousChild);
          if (self.log) |log| {
            try log.print("{s}previousChild {s}\n", .{ self.prefix.items, printKey(&previousChild) });
            try log.print("{s}previousGrandChild {s}\n", .{ self.prefix.items, printKey(&previousGrandChild) });
          }

          for (self.newChildren.items) |node| try self.set(txn, &node.key, &node.value);

          try self.delete(txn, &targetKey);
          
          var previousChildValue: Value = undefined;
          try self.hashRange(cursor, &previousGrandChild, &previousChildValue);
          try self.set(txn, &previousChild, &previousChildValue);

          if (isFirstChild or lessThan(getLeaf(&previousChild), getLeaf(firstChild))) {
            // if target is the first child, then we also have to delete our parent.
            if (isSplit(&previousChildValue)) {
              var node = Node{ .key = getParent(&previousChild), .value = undefined };
              try self.hashRange(cursor, &previousChild, &node.value);
              try self.newChildren.append(node);
            }

            parentResult = InsertResult.delete;
          } else if (std.mem.eql(u8, &previousChild, firstChild)) {
            // if the target is not the first child, we still need to check if the previous child
            // was the first child.
            if (isLeftEdge or isSplit(&previousChildValue)) {
              parentResult = InsertResult.update;
              try self.hashRange( cursor, firstChild, &self.parentValue);
            } else {
              parentResult = InsertResult.delete;
            }
          } else {
            parentResult = InsertResult.update;
            try self.hashRange(cursor, firstChild, &self.parentValue);
            if (isSplit(&previousChildValue)) {
              var node = Node{ .key = getParent(&previousChild), .value = undefined };
              try self.hashRange(cursor, &previousChild, &node.value);
              try self.newChildren.append(node);
            }
          }
        },
        InsertResult.update => {
          try self.set(txn, &targetKey, &self.parentValue);

          for (self.newChildren.items) |node| try self.set(txn, &node.key, &node.value);
          
          const isTargetSplit = isSplit(&self.parentValue);
          if (self.log) |log|
            try log.print("{s}isTargetSplit {d}\n", .{ self.prefix.items, isTargetSplit });

          if (isFirstChild) {
            // isFirstChild means either targetKey's original value was already a split, or isLeftEdge is true.
            if (isTargetSplit or isLeftEdge) {
              parentResult = InsertResult.update;
              try self.hashRange(cursor, &targetKey, &self.parentValue);
            } else {
              // !isTargetSplit && !isLeftEdge means that the current target
              // has lost its status as a split and needs to get merged left.
              parentResult = InsertResult.delete;
            }
          } else {
            parentResult = InsertResult.update;
            try self.hashRange(cursor, firstChild, &self.parentValue);

            if (isTargetSplit) {
              // create a parent of targetKey to add to newChildren
              var node = Node{ .key = getParent(&targetKey), .value = undefined };
              try self.hashRange(cursor, &targetKey, &node.value);
              try self.newChildren.append(node);
            }
          }
        },
      }

      for (self.newChildren.items[0..oldChildrenCount]) |oldChild| {
        if (isSplit(&oldChild.value)) {
          var newChild = Node{ .key = getParent(&oldChild.key), .value = undefined };
          try self.hashRange(cursor, &oldChild.key, &newChild.value);
          try self.newChildren.append(newChild);
        }
      }

      try self.newChildren.replaceRange(0, oldChildrenCount, &.{});

      return parentResult;
    }

    fn goToPreviousChild(self: *Tree(X, Q), txn: *Transaction(K, V), cursor: *Cursor(K, V), targetKey: *const Key) !Key {
      if (try cursor.goToKey(targetKey)) |_| {
        while (try cursor.goToPrevious()) |previousChild| {
          const previousGrandChild = getChild(previousChild);
          if (try self.get(txn, &previousGrandChild)) |previousGrandChildValue| {
            if (isSplit(previousGrandChildValue) or isKeyLeftEdge(&previousGrandChild)) {
              return createKey(getLevel(previousChild), getLeaf(previousChild));
            }
          }

          try self.delete(txn, previousChild);
        }
      }

      return Error.KeyNotFound;
    }

    fn findTargetKey(_: *const Tree(X, Q), cursor: *Cursor(K, V), firstChild: *const Key, leaf: *const Leaf) !Key {
      const level = getLevel(firstChild);
      assert(level > 0);

      if (try cursor.goToKey(firstChild)) |_| {
        var previousChild = createKey(level, getLeaf(firstChild));
        while (try cursor.goToNext()) |currentChild| {
          if (getLevel(currentChild) != level or lessThan(leaf, getLeaf(currentChild))) {
            return previousChild;
          } else {
            setLeaf(&previousChild, getLeaf(currentChild));
          }
        }

        return previousChild;
      } else {
        return Error.KeyNotFound;
      }
    }

    fn hashRange(self: *const Tree(X, Q), cursor: *Cursor(K, V), firstChild: *const Key, hash: *Value) !void {
      if (self.log) |log|
        try log.print("{s}hashRange({s})\n", .{ self.prefix.items, printKey(firstChild) });

      const level = getLevel(firstChild);

      _ = try cursor.goToKey(firstChild);
      var value = cursor.getCurrentValue().?;

      var digest = Sha256.init(.{});

      if (self.log) |log|
        try log.print("{s}- hashing {s} -> {s}\n", .{ self.prefix.items, printKey(firstChild), hex(value) });

      digest.update(value);

      while (try cursor.goToNext()) |key| {
        value = cursor.getCurrentValue().?;
        if (getLevel(key) == level and !isSplit(value)) {
          if (self.log) |log|
            try log.print("{s}- hashing {s} -> {s}\n", .{ self.prefix.items, printKey(key), hex(value) });

          digest.update(value);
        } else {
          break;
        }
      }

      digest.final(hash);
      if (self.log) |log|
        try log.print("{s}--------------------------- {s}\n", .{ self.prefix.items, hex(hash) });
    }


    var printKeyBuffer: [2+1+2*X]u8 = undefined;
    fn printKey(key: *const Key) []u8 {
      return std.fmt.bufPrint(&printKeyBuffer, "{d}:{s}", .{ getLevel(key), hex(getLeaf(key)) }) catch unreachable;
    }

    fn set(self: *Tree(X, Q), txn: *Transaction(K, V), key: *const Key, value: *const Value) !void {
      if (self.log) |log|
        try log.print("{s}txn.set({s}, {s})\n", .{ self.prefix.items, hex(key), hex(value) });

      try txn.set(self.dbi, key, value);
    }

    fn delete(self: *Tree(X, Q), txn: *Transaction(K, V), key: *const Key) !void {
      if (self.log) |log|
        try log.print("{s}txn.delete({s})\n", .{ self.prefix.items, hex(key) });

      try txn.delete(self.dbi, key);
    }

    fn get(self: *const Tree(X, Q), txn: *Transaction(K, V), key: *const Key) !?*Value {
      return txn.get(self.dbi, key);
    }

    // key utils
    fn setLevel(key: *Key, level: u16) void {
      std.mem.writeIntBig(u16, key[0..2], level);
    }

    fn getLevel(key: *const Key) u16 {
      return std.mem.readIntBig(u16, key[0..2]);
    }

    fn isKeyLeftEdge(key: *const Key) bool {
      for (key[2..]) |byte| if (byte != 0) return false;
      return true;
    }

    fn getLeaf(key: *const Key) *const Leaf {
      return key[2..];
    }

    fn setLeaf(key: *Key, leaf: *const Leaf) void {
      std.mem.copy(u8, key[2..], leaf);
    }

    fn createKey(level: u16, leaf: *const Leaf) Key {
      var key: Key = undefined;
      setLevel(&key, level);
      setLeaf(&key, leaf);
      return key;
    }

    fn getChild(key: *const Key) Key {
      const level = getLevel(key);
      assert(level > 0);
      return createKey(level - 1, getLeaf(key));
    }

    fn getParent(key: *const Key) Key {
      const level = getLevel(key);
      return createKey(level + 1, getLeaf(key));
    }

    fn lessThan(a: *const Leaf, b: *const Leaf) bool {
      return std.mem.lessThan(u8, a, b);
    }

    // value utils
    fn isSplit(value: *const Value) bool {
      return value[0] < Q;
    }
  };
}
