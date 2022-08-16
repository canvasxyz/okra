const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("./lmdb/lmdb.zig").lmdb;
const Environment = @import("./lmdb/environment.zig").Environment;
const EnvironmentOptions = @import("./lmdb/environment.zig").EnvironmentOptions;
const Transaction = @import("./lmdb/transaction.zig").Transaction;
const Cursor = @import("./lmdb/cursor.zig").Cursor;

const Key = @import("./key.zig").Key;

const constants = @import("./constants.zig");
const utils = @import("./utils.zig");
const print = @import("./print.zig");

const allocator = std.heap.c_allocator;

pub fn ReferenceTree(comptime X: usize) type {
  return struct {
    env: Environment,
    dbi: lmdb.MDB_dbi,
    txn: Transaction,
    key: Key(X),
    value: [32]u8 = constants.ZERO_HASH,

    pub fn init(path: []const u8, options: EnvironmentOptions) !ReferenceTree(X) {
      var env = try Environment.open(path, options);
      errdefer env.close();

      var txn = try Transaction.open(env, false);
      errdefer txn.abort();

      const dbi = try txn.openDbi();
      const key = Key(X).create(0, null);
      try txn.set(dbi, &key.bytes, &constants.ZERO_HASH);

      return ReferenceTree(X){ .env = env, .dbi = dbi, .txn = txn, .key = key };
    }

    pub fn insert(self: *ReferenceTree(X), key: *const [X]u8, value: *const [32]u8) !void {
      self.key.setData(key);
      try self.txn.set(self.dbi, &self.key.bytes, value);
    }

    pub fn finalize(self: *ReferenceTree(X)) !void {
      var cursor = try Cursor.open(self.txn, self.dbi);

      var level: u16 = 0;
      while ((try self.buildLevel(level, &cursor)) > 1) level += 1;

      cursor.close();
      try self.txn.commit();
      
      self.env.close();
    }

    fn buildLevel(self: *ReferenceTree(X), level: u16, cursor: *Cursor) !usize {
      var count: usize = 0;

      const leftEdge = Key(X).create(level, null);
      var anchor = try cursor.goToKey(&leftEdge.bytes);
      while (anchor) |anchorKey| {
        var anchorValue = cursor.getCurrentValue().?;
        assert(anchorValue.len == 32);

        var hash = Sha256.init(.{});
        hash.update(anchorValue);

        while (try cursor.goToNext()) |bytes| {
          const key = @ptrCast(*const Key(X), bytes.ptr);
          if (key.getLevel() > level) {
            anchor = null;
            hash.final(&self.value);
            const parentKey = @ptrCast(*const Key(X), anchorKey.ptr).getParent();
            try self.txn.set(self.dbi, &parentKey.bytes, &self.value);
            count += 1;
            break;
          }

          const value = cursor.getCurrentValue().?;
          assert(value.len == 32);
          if (utils.isValueSplit(value)) {
            anchor = bytes;
            hash.final(&self.value);
            const parentKey = @ptrCast(*const Key(X), anchorKey.ptr).getParent();
            try self.txn.set(self.dbi, &parentKey.bytes, &self.value);
            count += 1;
            break;
          } else {
            hash.update(value);
          }
        } else {
          anchor = null;
          hash.final(&self.value);
          const parentKey = @ptrCast(*const Key(X), anchorKey.ptr).getParent();
          try self.txn.set(self.dbi, &parentKey.bytes, &self.value);
          count += 1;
        }
      }
      return count;
    }
  };
}
