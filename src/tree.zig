const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("./lmdb/lmdb.zig").lmdb;
const Environment = @import("./lmdb/environment.zig").Environment;
const Transaction = @import("./lmdb/transaction.zig").Transaction;
const Cursor = @import("./lmdb/cursor.zig").Cursor;

const Key = @import("./key.zig").Key;

const constants = @import("./constants.zig");
const utils = @import("./utils.zig");
const print = @import("./print.zig");

const allocator = std.heap.c_allocator;

const InsertResult = enum { delete, update };

pub const TreeOptions = struct {
  log: ?std.fs.File.Writer = null,
  mapSize: usize = 10485760,
};

pub fn Tree(comptime X: usize) type {
  return struct {
    pub const Error = error {
      KeyNotFound,
    } || Transaction.Error || Cursor.Error || std.mem.Allocator.Error || std.os.WriteError;

    pub const Node = struct {
      key: Key(X),
      value: [32]u8,
    };

    env: Environment,
    dbi: lmdb.MDB_dbi,
    root: Key(X),
    parentValue: [32]u8 = constants.ZERO_HASH,
    newChildren: std.ArrayList(Node),
    log: ?std.fs.File.Writer,
    prefix: std.ArrayList(u8),

    pub fn open(path: []const u8, options: TreeOptions) !*Tree(X) {
      const tree = try allocator.create(Tree(X));
      errdefer allocator.destroy(tree);

      tree.log = options.log;
      tree.newChildren = std.ArrayList(Node).init(allocator);
      tree.prefix = std.ArrayList(u8).init(allocator);

      tree.env = try Environment.open(path, .{ .mapSize = options.mapSize });
      var txn = try Transaction.open(tree.env, false);
      errdefer txn.abort();

      tree.dbi = try txn.openDbi();
      var cursor = try Cursor.open(txn, tree.dbi);
      errdefer cursor.close();

      if (try cursor.goToLast()) |root| {
        assert(root.len == Key(X).SIZE);
        std.mem.copy(u8, &tree.root.bytes, root);
        assert(tree.root.isLeftEdge());
        assert(tree.root.getLevel() > 0);
      } else {
        std.mem.set(u8, &tree.root.bytes, 0);
        try txn.set(tree.dbi, &tree.root.bytes, &constants.ZERO_HASH);
        var value: [32]u8 = undefined;
        Sha256.hash(&[_]u8{}, &value, .{});
        tree.root.setLevel(1);
        try txn.set(tree.dbi, &tree.root.bytes, &value);
      }

      try txn.commit();
      return tree;
    }

    pub fn close(self: *Tree(X)) void {
      self.env.close();
      self.newChildren.deinit();
      allocator.destroy(self);
    }

    pub fn insert(self: *Tree(X), key: *const Key(X), value: *const [32]u8) Error!void {
      if (self.log) |log| {
        try log.print("insert {s} -> {s}\n", .{ try key.toString(), try utils.printHash(value) });
        try log.print("root   {s}\n", .{ try self.root.toString() });
      }

      var level = self.root.getLevel();
      assert(level > 0);

      var txn = try Transaction.open(self.env, false);
      var cursor = try Cursor.open(txn, self.dbi);

      try self.prefix.resize(0);
      try self.prefix.append('|');
      try self.prefix.append(' ');

      const firstChild = self.root.getChild();
      const result = switch (self.root.getLevel()) {
        1 => try self.insertLeaf(&txn, &cursor, &firstChild, key, value),
        else => try self.insertNode(&txn, &cursor, &firstChild, key, value, true),
      };

      assert(result == InsertResult.update);

      if (self.log) |log| {
        try log.print("parentValue: {s}\n", .{ try utils.printHash(&self.parentValue) });
        try log.print("newChildren: {d}\n", .{ self.newChildren.items.len });
        for (self.newChildren.items) |node| {
          try log.print("- {s} -> {s}\n", .{ try node.key.toString(), try utils.printHash(&node.value) });
        }
      }

      var newChildrenCount = self.newChildren.items.len;
      while (newChildrenCount > 0) : (newChildrenCount = self.newChildren.items.len) {
        try txn.set(self.dbi, &self.root.bytes, &self.parentValue);
        for (self.newChildren.items) |node| {
          try txn.set(self.dbi, &node.key.bytes, &node.value);
        }

        try self.hashRange(&cursor, &self.root, &self.parentValue);

        if (self.log) |log|
          try log.print("set new root value {s} -> {s}\n", .{ self.root.toString(), try utils.printHash(&self.parentValue) });

        level += 1;
        self.root.setLevel(level);

        for (self.newChildren.items) |newChild| {
          if (utils.isValueSplit(&newChild.value)) {
            var node = Node{ .key = newChild.key.getParent(), .value = undefined };
            try self.hashRange(&cursor, &newChild.key, &node.value);
            try self.newChildren.append(node);
          }
        }

        try self.newChildren.replaceRange(0, newChildrenCount, &.{});
      }

      try txn.set(self.dbi, &self.root.bytes, &self.parentValue);

      var lastKey = try cursor.goToLast();
      if (lastKey) |bytes| {
        const k = @ptrCast(*const Key(X), bytes.ptr);
        if (self.log) |log| {
          try log.print("lastKey: {s}\n", .{ k.toString() });
        }
      } else {
        @panic("internal error: no last key");
      }

      while (try cursor.goToPrevious()) |previousKeyBytes| {
        assert(previousKeyBytes.len == Key(X).SIZE);
        const previousKey = @ptrCast(*const Key(X), previousKeyBytes);
        if (previousKey.isLeftEdge()) {
          const newRoot = previousKey.clone();
          if (self.log) |log| try log.print("deleting root key: {s}\n", .{ try self.root.toString() });
          try txn.delete(self.dbi, &self.root.bytes);
          std.mem.copy(u8, &self.root.bytes, &newRoot.bytes);
          if (self.log) |log| try log.print("replaced root key: {s}\n", .{ try self.root.toString() });
        } else {
          break;
        }
      }

      cursor.close();
      try txn.commit();
    }

    fn insertLeaf(
      self: *Tree(X),
      txn: *Transaction,
      cursor: *Cursor,
      firstChild: *const Key(X),
      key: *const Key(X),
      value: *const [32]u8,
    ) Error!InsertResult {

      if (self.log) |log| {
        try log.print("{s}insertLeaf\n", .{ self.prefix.items });
        try log.print("{s}firstChild {s}\n", .{ self.prefix.items, try firstChild.toString() });
      }

      assert(firstChild.getLevel() == 0);
      assert(firstChild.lessThan(key));
      assert(key.getLevel() == 0);
      
      if (self.log) |log|
        try log.print("{s}insert key {s} -> {s}\n", .{ self.prefix.items, try key.toString(), try utils.printHash(value) });

      try txn.set(self.dbi, &key.bytes, value);

      try self.hashRange(cursor, firstChild, &self.parentValue);

      if (utils.isValueSplit(value)) {
        var node = Node{ .key = key.getParent(), .value = constants.ZERO_HASH };
        try self.hashRange(cursor, key, &node.value);
        try self.newChildren.append(node);
      }

      return InsertResult.update;
    }

    fn insertNode(
      self: *Tree(X),
      txn: *Transaction,
      cursor: *Cursor,
      firstChild: *const Key(X),
      key: *const Key(X),
      value: *const [32]u8,
      isLeftEdge: bool,
    ) Error!InsertResult {
      if (self.log) |log| try log.print("{s}firstChild {s}\n", .{ self.prefix.items, try firstChild.toString() });

      const level = firstChild.getLevel();
      assert(level > 0);
      assert(firstChild.lessThan(key));

      const targetKey = try self.findTargetKey(cursor, firstChild, key);
      if (self.log) |log| try log.print("{s}targetKey  {s}\n", .{ self.prefix.items, try targetKey.toString() });

      const isFirstChild = std.mem.eql(u8, &targetKey.bytes, &firstChild.bytes);
      if (self.log) |log| try log.print("{s}isFirstChild {d}\n", .{ self.prefix.items, isFirstChild });

      const depth = self.prefix.items.len;
      try self.prefix.append('|');
      try self.prefix.append(' ');

      const result = switch (level) {
        1 => try self.insertLeaf(txn, cursor, &targetKey.getChild(), key, value),
        else => try self.insertNode(txn, cursor, &targetKey.getChild(), key, value, isLeftEdge and isFirstChild),
      };

      try self.prefix.resize(depth);

      if (self.log) |log| switch (result) {
        InsertResult.delete =>
          try log.print("{s}delete key {s}\n", .{ self.prefix.items, targetKey.toString() }),
        InsertResult.update =>
          try log.print("{s}update key {s} -> {s}\n", .{self.prefix.items, targetKey.toString(), utils.printHash(&self.parentValue) }),
      };

      const oldChildrenCount = self.newChildren.items.len;

      var parentResult: InsertResult = undefined;

      switch (result) {
        InsertResult.delete => {
          assert(isLeftEdge == false or isFirstChild == false);

          const previousChild = try self.goToPreviousChild(txn, cursor, &targetKey);
          const previousGrandChild = previousChild.getChild();
          if (self.log) |log| {
            try log.print("{s}previousChild {s}\n", .{ self.prefix.items, previousChild.toString() });
            try log.print("{s}previousGrandChild {s}\n", .{ self.prefix.items, previousGrandChild.toString() });
          }

          for (self.newChildren.items) |node| {
            try txn.set(self.dbi, &node.key.bytes, &node.value);
          }

          if (self.log) |log| try log.print("{s}deleting {s}\n", .{ self.prefix.items, targetKey.toString() });
          try txn.delete(self.dbi, &targetKey.bytes);
          
          var previousChildValue: [32]u8 = undefined;
          try self.hashRange(cursor, &previousGrandChild, &previousChildValue);
          try txn.set(self.dbi, &previousChild.bytes, &previousChildValue);

          if (isFirstChild or previousChild.lessThan(firstChild)) {
            // if target is the first child, then we also have to delete our parent.
            if (utils.isValueSplit(&previousChildValue)) {
              var node = Node{ .key = previousChild.getParent(), .value = undefined };
              try self.hashRange(cursor, &previousChild, &node.value);
              try self.newChildren.append(node);
            }

            parentResult = InsertResult.delete;
          } else if (previousChild.equals(firstChild)) {
            // if the target is not the first child, we still need to check if the previous child
            // was the first child.
            if (isLeftEdge or utils.isValueSplit(&previousChildValue)) {
              parentResult = InsertResult.update;
              try self.hashRange( cursor, firstChild, &self.parentValue);
            } else {
              parentResult = InsertResult.delete;
            }
          } else {
            parentResult = InsertResult.update;
            try self.hashRange( cursor, firstChild, &self.parentValue);
            if (utils.isValueSplit(&previousChildValue)) {
              var node = Node{ .key = previousChild.getParent(), .value = undefined };
              try self.hashRange(cursor, &previousChild, &node.value);
              try self.newChildren.append(node);
            }
          }
        },
        InsertResult.update => {
          const isTargetSplit = utils.isValueSplit(&self.parentValue);
          try txn.set(self.dbi, &targetKey.bytes, &self.parentValue);

          if (self.log) |log|
            try log.print("{s}isTargetSplit {d}\n", .{ self.prefix.items, isTargetSplit });

          for (self.newChildren.items) |node| {
            try txn.set(self.dbi, &node.key.bytes, &node.value);
          }

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
              var node = Node{ .key = targetKey.getParent(), .value = undefined };
              try self.hashRange(cursor, &targetKey, &node.value);
              try self.newChildren.append(node);
            }
          }
        },
      }

      for (self.newChildren.items[0..oldChildrenCount]) |oldChild| {
        if (utils.isValueSplit(&oldChild.value)) {
          var newChild = Node{ .key = oldChild.key.getParent(), .value = undefined };
          try self.hashRange(cursor, &oldChild.key, &newChild.value);
          try self.newChildren.append(newChild);
        }
      }

      try self.newChildren.replaceRange(0, oldChildrenCount, &.{});

      return parentResult;
    }

    fn goToPreviousChild(self: *const Tree(X), txn: *Transaction, cursor: *Cursor, targetKey: *const Key(X)) !Key(X) {
      _ = try cursor.goToKey(&targetKey.bytes);
      while (try cursor.goToPrevious()) |previousBytes| {
        const previousChild = @ptrCast(*const Key(X), previousBytes);
        const previousGrandChild = previousChild.getChild();
        if (try txn.get(self.dbi, &previousGrandChild.bytes)) |previousGrandChildValue| {
          assert(previousGrandChildValue.len == 32);
          if (utils.isValueSplit(previousGrandChildValue) or previousGrandChild.isLeftEdge()) {
            return previousChild.clone();
          }
        }

        try txn.delete(self.dbi, previousBytes);
      }

      return Error.KeyNotFound;
    }

    fn findTargetKey(_: *const Tree(X), cursor: *Cursor, firstChild: *const Key(X), key: *const Key(X)) !Key(X) {
      const level = firstChild.getLevel();
      assert(level > 0);

      _ = (try cursor.goToKey(&firstChild.bytes)) orelse return Tree(X).Error.KeyNotFound;
      var previousChild = firstChild.clone();
      var next = try cursor.goToNext();
      while (next) |bytes| : (next = try cursor.goToNext()) {
        assert(bytes.len == Key(X).SIZE);
        const currentChild = @ptrCast(*const Key(X), bytes);
        if (currentChild.getLevel() != level or key.lessThan(currentChild)) {
          return previousChild;
        } else {
          previousChild.setData(currentChild.getData());
        }
      }

      return previousChild;
    }

    fn hashRange(self: *const Tree(X), cursor: *Cursor, firstChild: *const Key(X), hash: *[32]u8) !void {
      if (self.log) |log|
        try log.print("{s}hash range {s}\n", .{ self.prefix.items, firstChild.toString() });

      const level = firstChild.getLevel();

      var digest = Sha256.init(.{});
      var child = try cursor.goToKey(&firstChild.bytes);
      assert(child != null);

      var key = @ptrCast(*const Key(X), child.?.ptr);
      var value = cursor.getCurrentValue().?;

      if (self.log) |log|
        try log.print("{s}-- hashing {s} -> {s}\n", .{ self.prefix.items, try key.toString(), try utils.printHash(value) });
      digest.update(value);

      while (try cursor.goToNext()) |bytes| {
        assert(bytes.len == Key(X).SIZE);
        key = @ptrCast(*const Key(X), bytes.ptr);
        value = cursor.getCurrentValue().?;
        assert(value.len == 32);

        if (key.getLevel() == level and !utils.isValueSplit(value)) {
          if (self.log) |log|
            try log.print("{s}-- hashing {s} -> {s}\n", .{ self.prefix.items, try key.toString(), try utils.printHash(value) });

          digest.update(value);
        } else {
          break;
        }
      }

      digest.final(hash);
      if (self.log) |log|
        try log.print("{s}------------------------------- {s}\n", .{ self.prefix.items, try utils.printHash(hash) });
    }
  };
}
