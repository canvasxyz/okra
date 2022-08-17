const std = @import("std");
const expectEqualSlices = std.testing.expectEqualSlices;
const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("./lmdb/lmdb.zig").lmdb;
const Environment = @import("./lmdb/environment.zig").Environment;
const Transaction = @import("./lmdb/transaction.zig").Transaction;
const Cursor = @import("./lmdb/cursor.zig").Cursor;

const utils = @import("./utils.zig");

const allocator = std.heap.c_allocator;

const Options = struct {
  mapSize: usize = 10485760,
};

pub fn Builder(comptime X: usize, comptime Q: u8) type {
  const K = 2 + X;
  const V = 32;

  return struct {
    pub const Leaf = [X]u8;
    pub const Key = [K]u8;
    pub const Value = [V]u8;

    env: Environment(K, V),
    dbi: lmdb.MDB_dbi,
    txn: Transaction(K, V),
    key: Key = [_]u8{ 0 } ** K,
    value: Value = [_]u8{ 0 } ** V,

    pub fn init(path: []const u8, options: Options) !Builder(X, Q) {
      var env = try Environment(K, V).open(path, .{ .mapSize = options.mapSize });
      errdefer env.close();

      var txn = try Transaction(K, V).open(env, false);
      errdefer txn.abort();

      const dbi = try txn.openDbi();

      const builder = Builder(X, Q){ .env = env, .dbi = dbi, .txn = txn };
      try txn.set(dbi, &builder.key, &builder.value);
      return builder;
    }

    pub fn insert(self: *Builder(X, Q), key: *const [X]u8, value: *const [32]u8) !void {
      std.mem.copy(u8, self.key[2..], key);
      try self.txn.set(self.dbi, &self.key, value);
    }

    pub fn finalize(self: *Builder(X, Q), root: ?*[32]u8) !u16 {
      var cursor = try Cursor(K, V).open(self.txn, self.dbi);

      var level: u16 = 0;
      while ((try self.buildLevel(level, &cursor)) > 1) level += 1;

      if (root) |ptr| {
        _ = try cursor.goToLast();
        std.mem.copy(u8, ptr, cursor.getCurrentValue().?);
      }

      cursor.close();
      try self.txn.commit();
      
      self.env.close();
      return level + 1;
    }

    fn buildLevel(self: *Builder(X, Q), level: u16, cursor: *Cursor(K, V)) !usize {
      var count: usize = 0;

      std.mem.writeIntBig(u16, self.key[0..2], level);
      std.mem.set(u8, self.key[2..], 0);
      var anchor = try cursor.goToKey(&self.key);
      while (anchor) |anchorKey| {
        // save the anchor key
        std.mem.copy(u8, &self.key, anchorKey);

        var hash = Sha256.init(.{});
        hash.update(cursor.getCurrentValue().?);

        while (try cursor.goToNext()) |key| {
          if (std.mem.readIntBig(u16, key[0..2]) > level) {
            std.mem.writeIntBig(u16, self.key[0..2], level + 1);
            hash.final(&self.value);
            try self.txn.set(self.dbi, &self.key, &self.value);

            count += 1;
            anchor = null;
            break;
          }

          const value = cursor.getCurrentValue().?;
          if (value[0] < Q) {
            std.mem.writeIntBig(u16, self.key[0..2], level + 1);
            hash.final(&self.value);
            try self.txn.set(self.dbi, &self.key, &self.value);

            count += 1;
            anchor = key;
            break;
          } else {
            hash.update(value);
          }
        } else {
          std.mem.writeIntBig(u16, self.key[0..2], level + 1);
          hash.final(&self.value);
          try self.txn.set(self.dbi, &self.key, &self.value);

          count += 1;
          anchor = null;
        }
      }

      return count;
    }
  };
}

fn testIota(comptime X: usize, comptime Q: u8, comptime N: u16, expected: *const [32]u8) !void {
  var tmp = std.testing.tmpDir(.{});

  const path = try utils.resolvePath(allocator, tmp.dir, "reference.mdb");
  defer allocator.free(path);

  var referenceTree = try Builder(X, Q).init(path, .{});

  var key = [_]u8{ 0 } ** X;
  var value: [32]u8 = undefined;

  var i: u16 = 0;
  while (i < N) : (i += 1) {
    std.mem.writeIntBig(u16, key[X-2..], i + 1);
    Sha256.hash(&key, &value, .{});
    try referenceTree.insert(&key, &value);
  }

  var actual: [32]u8 = undefined;
  _ = try referenceTree.finalize(&actual);

  try expectEqualSlices(u8, expected, &actual);

  tmp.cleanup();
}

test "testIota(6, 0x20, 10)" {
  const expected = utils.parseHash("3cf9c6cab5d9f9cadf51b7fe3a8f9215e0b7ec0fe9e87a3e22678fa5009862d3");
  try testIota(6, 0x20, 10, &expected);
}

test "testIota(6, 0x30, 10)" {
  const expected = utils.parseHash("c786feeecdff049766bbbd49adc0a3ec47016c39d725f10c4d405931283fa93c");
  try testIota(6, 0x30, 10, &expected);  
}

test "testIota(6, 0x42, 10)" {
  const expected = utils.parseHash("d42d03b3176a17c253875be90daaf2cb58c8beb00c612d36410a13793aa03c7c");
  try testIota(6, 0x42, 10, &expected);  
}

test "testIota(6, 0x20, 100)" {
  const expected = utils.parseHash("c49441921bb10659e23b703c7d028fc8b5f677b2df042b9bd043703771b145a6");
  try testIota(6, 0x20, 100, &expected);
}

test "testIota(6, 0x30, 100)" {
  const expected = utils.parseHash("523f3244068a31634b1acf2d8637fbbf02c1e920e27d007f01237aca894216d3");
  try testIota(6, 0x30, 100, &expected);
}

test "testIota(6, 0x20, 1000)" {
  const expected = utils.parseHash("56759fe8e408eda58af94bb89140e1621a69b16f813599eb027f2f0ba8067f11");
  try testIota(6, 0x20, 1000, &expected);
}

test "testIota(6, 0x30, 1000)" {
  const expected = utils.parseHash("5c05e591d73de7635e28d5c0147e7ff5fa36c8f80ec79a0a73d4db6af4f35135");
  try testIota(6, 0x30, 1000, &expected);
}

test "testIota(6, 0x20, 10000)" {
  const expected = utils.parseHash("aaea41e828b19f6d89bdf943e67877dee1f500db8cd2becf050f42dae815e668");
  try testIota(6, 0x20, 10000, &expected);
}

test "testIota(6, 0x30, 10000)" {
  const expected = utils.parseHash("470fe0318cf569eb22250484312a3ed3bbd53252edfa4724378e500986bda706");
  try testIota(6, 0x30, 10000, &expected);
}
