const std = @import("std");
const expectEqualSlices = std.testing.expectEqualSlices;
const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("lmdb");

const utils = @import("./utils.zig");

const allocator = std.heap.c_allocator;

const Options = struct {
  mapSize: usize = 10485760,
};

/// A Builder is naive bottom-up tree builder used to construct large trees
/// at once and for reference when unit testing the actual Tree.
/// Create a builder with Builder.init(path, options), insert as many leaves
/// as you want using .insert(key, value), and then call .finalize().
/// Builder is also used in the rebuild cli command.
pub fn Builder(comptime X: usize, comptime Q: u8) type {
  const K = 2 + X;
  const V = 32;

  return struct {
    pub const Leaf = [X]u8;
    pub const Key = [K]u8;
    pub const Value = [V]u8;

    env: lmdb.Environment(K, V),
    dbi: lmdb.DBI,
    txn: lmdb.Transaction(K, V),
    key: Key = [_]u8{ 0 } ** K,
    value: Value = [_]u8{ 0 } ** V,

    pub fn init(path: [*:0]const u8, options: Options) !Builder(X, Q) {
      var env = try lmdb.Environment(K, V).open(path, .{ .mapSize = options.mapSize });
      errdefer env.close();

      var txn = try lmdb.Transaction(K, V).open(env, false);
      errdefer txn.abort();

      const dbi = try txn.openDBI();

      const builder = Builder(X, Q){ .env = env, .dbi = dbi, .txn = txn };
      try txn.set(dbi, &builder.key, &builder.value);
      return builder;
    }

    pub fn insert(self: *Builder(X, Q), leaf: *const [X]u8, hash: *const [32]u8) !void {
      std.mem.copy(u8, self.key[2..], leaf);
      try self.txn.set(self.dbi, &self.key, hash);
    }

    pub fn finalize(self: *Builder(X, Q), root: ?*[32]u8) !u16 {
      var cursor = try lmdb.Cursor(K, V).open(self.txn, self.dbi);

      var level: u16 = 0;
      while ((try self.buildLevel(level, &cursor)) > 1) level += 1;

      if (root) |ptr| {
        _ = try cursor.goToLast();
        std.mem.copy(u8, ptr, try cursor.getCurrentValue());
      }

      cursor.close();
      try self.txn.commit();
      
      self.env.close();
      return level + 1;
    }

    fn getLevel(key: *const [K]u8) u16 {
      return std.mem.readIntBig(u16, key[0..2]);
    }

    fn setLevel(key: *[K]u8, level: u16) void {
      std.mem.writeIntBig(u16, key[0..2], level);
    }

    fn buildLevel(self: *Builder(X, Q), level: u16, cursor: *lmdb.Cursor(K, V)) !usize {
      var count: usize = 0;

      setLevel(&self.key, level);
      std.mem.set(u8, self.key[2..], 0);
      try cursor.goToKey(&self.key);

      var hash = Sha256.init(.{});
      hash.update(try cursor.getCurrentValue());

      while (try cursor.goToNext()) |key| {
        if (getLevel(key) != level) break;

        const value = try cursor.getCurrentValue();
        if (value[0] < Q) {
          hash.final(&self.value);
          setLevel(&self.key, level + 1);
          try self.txn.set(self.dbi, &self.key, &self.value);
          count += 1;

          hash = Sha256.init(.{});
          hash.update(value);
          std.mem.copy(u8, &self.key, key);
        } else {
          hash.update(value);
        }
      }

      hash.final(&self.value);
      setLevel(&self.key, level + 1);
      try self.txn.set(self.dbi, &self.key, &self.value);
      count += 1;

      return count;
    }
  };
}

fn testIota(comptime X: usize, comptime Q: u8, comptime N: u16, expected: *const [32]u8) !void {
  var tmp = std.testing.tmpDir(.{});
  const tmpPath = try tmp.dir.realpath(".", &utils.pathBuffer);
  const path = try std.fs.path.joinZ(allocator, &[_][]const u8{ tmpPath, "reference.mdb" });
  defer allocator.free(path);

  var builder = try Builder(X, Q).init(path, .{});

  var key = [_]u8{ 0 } ** X;
  var value: [32]u8 = undefined;

  var i: u16 = 0;
  while (i < N) : (i += 1) {
    std.mem.writeIntBig(u16, key[X-2..], i + 1);
    Sha256.hash(&key, &value, .{});
    try builder.insert(&key, &value);
  }

  var actual: [32]u8 = undefined;
  _ = try builder.finalize(&actual);

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
