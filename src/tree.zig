const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");

const InsertResultTag = enum { delete, update };
const InsertResult = union(InsertResultTag) {
  delete: void,
  update: [32]u8,
};

const Options = struct {
  log: ?std.fs.File.Writer = null,
  mapSize: usize = 10485760,
};

/// A Tree is a struct generic in two paramers X and Q.
/// X is the byte size of leaf keys and for now(due to alignment issues)
/// must be two less than a multiple of eight.
/// Q is the fanout degree expressed as a u8 limit: hashes whose
/// first byte are less than Q are considered splits.
/// Open a tree with Tree.open(path, .{}), insert leaves with
/// tree.insert(leaf, hash), and close the tree with tree.close().
pub fn Tree(comptime X: usize, comptime Q: u8) type {
  return struct {
    const K = 2 + X;
    const V = 32;
    pub const Env = lmdb.Environment(K, V);
    pub const Txn = lmdb.Transaction(K, V);
    pub const Cursor = lmdb.Cursor(K, V);

    pub const Error = error {
      InsertError,
      InvalidDatabase,
      KeyNotFound,
      Duplicate,
    } || Txn.Error || Cursor.Error || std.mem.Allocator.Error || std.os.WriteError;

    pub const Leaf = [X]u8;
    pub const Key = [K]u8;
    pub const Value = [V]u8;
    pub const Node = struct { key: Key, value: Value };

    env: Env,
    dbi: lmdb.DBI,

    rootLevel: u16,
    rootValue: Value,
    newChildren: std.ArrayList(Node),

    prefix: std.ArrayList(u8),
    log: ?std.fs.File.Writer,

    pub fn init(self: *Tree(X, Q), allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void {
      self.log = options.log;
      self.env = try Env.open(path, .{ .mapSize = options.mapSize });

      self.newChildren = std.ArrayList(Node).init(allocator);
      self.prefix = std.ArrayList(u8).init(allocator);

      var txn = try Txn.open(self.env, false);
      errdefer txn.abort();

      self.dbi = try txn.openDBI();

      var cursor = try Cursor.open(txn, self.dbi);
      errdefer cursor.close();

      if (try cursor.goToLast()) |root| {
        self.rootLevel = getLevel(root);
        if (self.rootLevel == 0 or !isKeyLeftEdge(root)) {
          return Error.InvalidDatabase;
        }
        std.mem.copy(u8, &self.rootValue, try cursor.getCurrentValue());
      } else {
        var key = [_]u8 { 0 } ** K;
        var value = [_]u8{ 0 } ** V;
        try self.set(&txn, &key, &value);
        Sha256.hash(&value, &self.rootValue, .{});
        setLevel(&key, 1);
        try self.set(&txn, &key, &self.rootValue);
        self.rootLevel = 1;
      }

      try txn.commit();
    }

    pub fn close(self: *Tree(X, Q)) void {
      self.env.close();
      self.newChildren.deinit();
      self.prefix.deinit();
    }

    pub fn transaction(self: *Tree(X, Q)) !Txn {
      return try Txn.open(self.env, false);
    }

    pub fn insert(self: *Tree(X, Q), leaf: *const Leaf, value: *const Value) !void {
      var txn = try Txn.open(self.env, false);
      errdefer txn.abort();

      const key = createKey(0, leaf);
      if (try self.get(&txn, &key)) |_| {
        return Error.Duplicate;
      }

      var cursor = try Cursor.open(txn, self.dbi);
      errdefer cursor.close();

      try self.update(&txn, &cursor, leaf, value);

      cursor.close();
      try txn.commit();
    }

    pub fn insertTxn(self: *Tree(X, Q), leaf: *const Leaf, value: *const Value, txn: *Txn) !void {
      const key = createKey(0, leaf);
      if (try self.get(txn, &key)) |_| {
        return Error.Duplicate;
      }

      var cursor = try Cursor.open(txn, self.dbi);
      defer cursor.close();

      try self.update(txn, &cursor, leaf, value);
    }

    fn update(
      self: *Tree(X, Q),
      txn: *Txn,
      cursor: *Cursor,
      leaf: *const Leaf,
      value: *const Value,
    ) Error!void {
      if (self.log) |log| {
        try log.print("insert({s}, {s})\n", .{ hex(leaf), hex(value) });
        try log.print("rootLevel {d}\n", .{ self.rootLevel });
        try self.prefix.resize(0);
        try self.prefix.append('|');
        try self.prefix.append(' ');
      }

      if (self.rootLevel == 0) return Error.InvalidDatabase;

      const firstChild = createKey(self.rootLevel - 1, null);

      const result = switch (self.rootLevel) {
        1 => try self.insertLeaf(txn, cursor, &firstChild, leaf, value),
        else => try self.insertNode(txn, cursor, &firstChild, leaf, value, true),
      };

      assert(result == InsertResult.update);
      var rootValue = switch (result) {
        .update => |rootValue| rootValue,
        .delete => return Error.InsertError,
      };

      if (self.log) |log| {
        try self.prefix.resize(0);
        try log.print("new root {d} -> {s}\n", .{ self.rootLevel, hex(&rootValue) });
        try log.print("newChildren: {d}\n", .{ self.newChildren.items.len });
        for (self.newChildren.items) |node|
          try log.print("- {s} -> {s}\n", .{ printKey(&node.key), hex(&node.value) });
      }

      var rootKey = createKey(self.rootLevel, null);
      var newChildrenCount = self.newChildren.items.len;
      while (newChildrenCount > 0) : (newChildrenCount = self.newChildren.items.len) {
        try self.set(txn, &rootKey, &rootValue);
        for (self.newChildren.items) |node| try self.set(txn, &node.key, &node.value);

        try self.hashRange(cursor, &rootKey, &rootValue);

        self.rootLevel += 1;
        setLevel(&rootKey, self.rootLevel);

        for (self.newChildren.items) |newChild| {
          if (isSplit(&newChild.value)) {
            var node = Node{ .key = getParent(&newChild.key), .value = undefined };
            try self.hashRange(cursor, &newChild.key, &node.value);
            try self.newChildren.append(node);
          }
        }

        try self.newChildren.replaceRange(0, newChildrenCount, &.{});
        if (self.log) |log| {
          try log.print("new root {d} -> {s}\n", .{ self.rootLevel, hex(&rootValue) });
          try log.print("newChildren: {d}\n", .{ self.newChildren.items.len });
          for (self.newChildren.items) |node|
            try log.print("- {s} -> {s}\n", .{ printKey(&node.key), hex(&node.value) });
        }
      }

      try self.set(txn, &rootKey, &rootValue);
      self.rootValue = rootValue;

      if (try cursor.goToLast()) |lastKey| {
        if (self.log) |log| try log.print("last key: {s}\n", .{ printKey(lastKey) });
      } else {
        return Error.InvalidDatabase;
      }

      while (try cursor.goToPrevious()) |previousKey| {
        if (!isKeyLeftEdge(previousKey)) break;
        self.rootLevel = getLevel(previousKey);
        std.mem.copy(u8, &self.rootValue, try cursor.getCurrentValue());
        try self.delete(txn, &rootKey);
        setLevel(&rootKey, self.rootLevel);
        if (self.log) |log| try log.print("replaced root key: {d}\n", .{ self.rootLevel });
      }
    }

    fn insertLeaf(
      self: *Tree(X, Q),
      txn: *Txn,
      cursor: *Cursor,
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

      var parentValue: Value = undefined;
      try self.hashRange(cursor, firstChild, &parentValue);

      if (isSplit(value)) {
        var node = Node{ .key = getParent(&key), .value = undefined };
        try self.hashRange(cursor, &key, &node.value);
        try self.newChildren.append(node);
      }

      return InsertResult{ .update = parentValue };
    }

    fn insertNode(
      self: *Tree(X, Q),
      txn: *Txn,
      cursor: *Cursor,
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

            parentResult = InsertResult{ .delete = {} };
          } else if (std.mem.eql(u8, &previousChild, firstChild)) {
            // if the target is not the first child, we still need to check if the previous child
            // was the first child.
            if (isLeftEdge or isSplit(&previousChildValue)) {
              parentResult = InsertResult{ .update = undefined };
              try self.hashRange( cursor, firstChild, &parentResult.update);
            } else {
              parentResult = InsertResult{ .delete = {} };
            }
          } else {
            parentResult = InsertResult{ .update = undefined };
            try self.hashRange(cursor, firstChild, &parentResult.update);
            if (isSplit(&previousChildValue)) {
              var node = Node{ .key = getParent(&previousChild), .value = undefined };
              try self.hashRange(cursor, &previousChild, &node.value);
              try self.newChildren.append(node);
            }
          }
        },
        InsertResult.update => |parentValue| {
          try self.set(txn, &targetKey, &parentValue);

          for (self.newChildren.items) |node| try self.set(txn, &node.key, &node.value);
          
          const isTargetSplit = isSplit(&parentValue);
          if (self.log) |log|
            try log.print("{s}isTargetSplit {d}\n", .{ self.prefix.items, isTargetSplit });

          if (isFirstChild) {
            // isFirstChild means either targetKey's original value was already a split, or isLeftEdge is true.
            if (isTargetSplit or isLeftEdge) {
              parentResult = InsertResult{ .update = undefined };
              try self.hashRange(cursor, &targetKey, &parentResult.update);
            } else {
              // !isTargetSplit && !isLeftEdge means that the current target
              // has lost its status as a split and needs to get merged left.
              parentResult = InsertResult{ .delete = {} };
            }
          } else {
            parentResult = InsertResult{ .update = undefined };
            try self.hashRange(cursor, firstChild, &parentResult.update);

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

    fn goToPreviousChild(self: *Tree(X, Q), txn: *Txn, cursor: *Cursor, targetKey: *const Key) !Key {
      try cursor.goToKey(targetKey);
      while (try cursor.goToPrevious()) |previousChild| {
        const previousGrandChild = getChild(previousChild);
        if (try self.get(txn, &previousGrandChild)) |previousGrandChildValue| {
          if (isSplit(previousGrandChildValue) or isKeyLeftEdge(&previousGrandChild)) {
            return createKey(getLevel(previousChild), getLeaf(previousChild));
          }
        }

        try self.delete(txn, previousChild);
      }

      return Error.KeyNotFound;
    }

    fn findTargetKey(_: *const Tree(X, Q), cursor: *Cursor, firstChild: *const Key, leaf: *const Leaf) !Key {
      const level = getLevel(firstChild);
      assert(level > 0);

      try cursor.goToKey(firstChild);
      var previousChild = createKey(level, getLeaf(firstChild));
      while (try cursor.goToNext()) |currentChild| {
        if (getLevel(currentChild) != level or lessThan(leaf, getLeaf(currentChild))) {
          return previousChild;
        } else {
          setLeaf(&previousChild, getLeaf(currentChild));
        }
      }

      return previousChild;
    }

    fn hashRange(self: *const Tree(X, Q), cursor: *Cursor, firstChild: *const Key, hash: *Value) !void {
      if (self.log) |log|
        try log.print("{s}hashRange({s})\n", .{ self.prefix.items, printKey(firstChild) });

      const level = getLevel(firstChild);
      try cursor.goToKey(firstChild);
      var value = try cursor.getCurrentValue();

      var digest = Sha256.init(.{});

      if (self.log) |log|
        try log.print("{s}- hashing {s} -> {s}\n", .{ self.prefix.items, printKey(firstChild), hex(value) });

      digest.update(value);

      while (try cursor.goToNext()) |key| {
        value = try cursor.getCurrentValue();
        if (getLevel(key) != level or isSplit(value)) break;
        if (self.log) |log|
          try log.print("{s}- hashing {s} -> {s}\n", .{ self.prefix.items, printKey(key), hex(value) });

        digest.update(value);
      }

      digest.final(hash);
      if (self.log) |log|
        try log.print("{s}--------------------------- {s}\n", .{ self.prefix.items, hex(hash) });
    }

    var printKeyBuffer: [2+1+2*X]u8 = undefined;
    pub fn printKey(key: *const Key) []u8 {
      return std.fmt.bufPrint(&printKeyBuffer, "{d}:{s}", .{ getLevel(key), hex(getLeaf(key)) }) catch unreachable;
    }

    pub fn parseKey(name: *const [2+2*X]u8) Key {
      var key: Key = undefined;
      const level = std.fmt.parseInt(u16, name[0..1], 10) catch unreachable;
      setLevel(&key, level);

      _ = std.fmt.hexToBytes(key[2..], name[2..]) catch unreachable;
      return key;
    }

    fn set(self: *Tree(X, Q), txn: *Txn, key: *const Key, value: *const Value) !void {
      if (self.log) |log|
        try log.print("{s}txn.set({s}, {s})\n", .{ self.prefix.items, hex(key), hex(value) });

      try txn.set(self.dbi, key, value);
    }

    fn delete(self: *Tree(X, Q), txn: *Txn, key: *const Key) !void {
      if (self.log) |log|
        try log.print("{s}txn.delete({s})\n", .{ self.prefix.items, hex(key) });

      try txn.delete(self.dbi, key);
    }

    fn get(self: *const Tree(X, Q), txn: *Txn, key: *const Key) !?*Value {
      return txn.get(self.dbi, key);
    }

    // key utils
    pub fn setLevel(key: *Key, level: u16) void {
      std.mem.writeIntBig(u16, key[0..2], level);
    }

    pub fn getLevel(key: *const Key) u16 {
      return std.mem.readIntBig(u16, key[0..2]);
    }

    pub fn isKeyLeftEdge(key: *const Key) bool {
      for (key[2..]) |byte| if (byte != 0) return false;
      return true;
    }

    pub fn getLeaf(key: *const Key) *const Leaf {
      return key[2..];
    }

    pub fn setLeaf(key: *Key, leaf: ?*const Leaf) void {
      if (leaf) |bytes| {
        std.mem.copy(u8, key[2..], bytes);
      } else {
        std.mem.set(u8, key[2..], 0);
      }
    }

    pub fn createKey(level: u16, leaf: ?*const Leaf) Key {
      var key: Key = undefined;
      setLevel(&key, level);
      setLeaf(&key, leaf);
      return key;
    }

    pub fn getChild(key: *const Key) Key {
      const level = getLevel(key);
      assert(level > 0);
      return createKey(level - 1, getLeaf(key));
    }

    pub fn getParent(key: *const Key) Key {
      const level = getLevel(key);
      return createKey(level + 1, getLeaf(key));
    }

    pub fn lessThan(a: ?*const Leaf, b: ?*const Leaf) bool {
      if (b) |bytesB| {
        if (a) |bytesA| {
          return std.mem.lessThan(u8, bytesA, bytesB);
        } else if (std.mem.max(u8, bytesB) == 0) {
          return false;
        }
      }

      return false;
    }

    // value utils
    pub fn isSplit(value: *const Value) bool {
      return value[0] < Q;
    }
  };
}
