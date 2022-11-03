const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

const lmdb = @import("lmdb");
const okra = @import("./lib.zig");
const utils = @import("./utils.zig");

// Source and Target are designed to expose the basic operations required by each participant,
// but there is still a "driver" component that wires them together and encapsulates any async
// or streaming logic if the source and target are not in the same process.

// The struct here is a sync Zig reference implementation of the driver algorithm,
// used for unit-testing Target and by the CLI.
fn Driver(comptime X: usize, comptime Q: u8) type {
  return struct {
    const K = 2 + X;
    const V = 32;
    const Txn = lmdb.Transaction(K, V);
    const Cursor = lmdb.Cursor(K, V);
    const Node = okra.Node(X);
    const Tree = okra.Tree(X, Q);
    const Source = okra.Source(X, Q);
    const Target = okra.Target(X, Q);
    const Error = Target.Error || Source.Error || Txn.Error || Cursor.Error || std.mem.Allocator.Error;

    allocator: std.mem.Allocator,
    source: Source,
    target: Target,
    calls: u32,

    pub fn init(self: *Driver(X, Q), allocator: std.mem.Allocator, target: *Tree, source: *Tree) !void {
      self.allocator = allocator;
      self.calls = 0;
      try self.target.init(allocator, target);
      try self.source.init(allocator, source);
    }

    pub fn close(self: *Driver(X, Q)) void {
      self.source.close();
      self.target.close();
    }

    pub fn sync(self: *Driver(X, Q)) !void {
      var leaves = std.ArrayList(Node).init(self.allocator);
      defer leaves.deinit();
      try self.exec(&leaves);
      for (leaves.items) |node| {
        // std.log.warn("inserting {s} -> {s}", .{ hex(&node.leaf), hex(&node.hash) });
        try self.target.tree.insert(&node.leaf, &node.hash);
      }
    }

    pub fn exec(self: *Driver(X, Q), leaves: *std.ArrayList(Node)) !void {
      const sourceRoot = [_]u8{ 0 } ** X;
      try self.enter(self.target.rootLevel, self.source.rootLevel, &sourceRoot, &self.source.rootValue, leaves);
    }

    fn enter(
      self: *Driver(X, Q),
      targetLevel: u16,
      sourceLevel: u16,
      sourceRoot: *const Tree.Leaf,
      sourceHash: *const Tree.Value,
      leaves: *std.ArrayList(Node),
    ) Error!void {
      // So the first step here is to figure out which tree is taller.
      // If the source tree is taller, then we need to use the source to iterate over all the chunks
      // at the target tree's root level and re-enter from all of them.
      // If the target tree is taller, we actually just call scan once,
      // but starting at the left edge on the source tree root's level.
      // std.log.warn(
      //   "enter(targetLevel: {d}, sourceLevel: {d}, sourceRoot: {s}, sourceHash: {s})",
      //   .{ targetLevel, sourceLevel, hex(sourceRoot), hex(sourceHash) },
      // );

      if (sourceLevel > targetLevel) {
        var nodes = std.ArrayList(Node).init(self.allocator);
        defer nodes.deinit();
        try self.source.getChildren(sourceLevel, sourceRoot, &nodes);
        self.calls += 1;
        assert(nodes.items.len > 0);

        for (nodes.items) |node| {
          try self.enter(targetLevel, sourceLevel - 1, &node.leaf, &node.hash, leaves);
        }
      } else {
        try self.scan(sourceLevel, sourceRoot, sourceHash, leaves);
      }
    }

    fn scan(
      self: *Driver(X, Q),
      level: u16,
      sourceRoot: *const Tree.Leaf,
      sourceHash: *const Tree.Value,
      leaves: *std.ArrayList(Node),
    ) Error!void {
      const pointer = try self.target.seek(level, sourceRoot);
      if (std.mem.eql(u8, sourceRoot, Tree.getLeaf(pointer.key))) {
        if (std.mem.eql(u8, sourceHash, pointer.value)) {
          return;
        }
      }

      var nodes = std.ArrayList(Node).init(self.allocator);
      defer nodes.deinit();
      try self.source.getChildren(level, sourceRoot, &nodes);
      self.calls += 1;
      assert(nodes.items.len > 0);

      if (level > 1) {
        for (nodes.items) |node| try self.scan(level - 1, &node.leaf, &node.hash, leaves);
      } else {
        assert(level == 1);
        try self.target.filter(nodes.items, leaves);
      }
    }
  };
}

test "sync iota(100) into an empty tree" {
  const X = 6;
  const Q = 0x42;
  const Node = okra.Node(X);
  const Tree = okra.Tree(X, Q);
  const allocator = std.heap.c_allocator;

  std.debug.print("\n", .{});

  var tmp = std.testing.tmpDir(.{});
  defer tmp.cleanup();

  const sourcePath = try utils.resolvePath(allocator, tmp.dir, "source.mdb");
  defer allocator.free(sourcePath);

  const targetPath = try utils.resolvePath(allocator, tmp.dir, "target.mdb");
  defer allocator.free(targetPath);

  var source: Tree = undefined;
  try source.init(allocator, sourcePath, .{ });
  defer source.close();

  var target: Tree = undefined;
  try target.init(allocator, targetPath, .{ });
  defer target.close();

  try iota(X, Q, &source, 100, null);

  // targetToSource
  {
    var driver: Driver(X, Q) = undefined;
    try driver.init(allocator, &source, &target);
    defer driver.close();

    var leaves = std.ArrayList(Node).init(allocator);
    defer leaves.deinit();

    try driver.exec(&leaves);
    try expectEqualSlices(Node, leaves.items, &.{});
  }

  // sourceToTarget
  {
    var driver: Driver(X, Q) = undefined;
    try driver.init(allocator, &target, &source);
    defer driver.close();

    try driver.sync();

    try expectEqualSlices(u8, &source.rootValue, &target.rootValue);
  }
}

// The rest of the tests here all create a "skip set",
// which is a HashMap(u32, bool) of elements to exclude from the target tree.

test "sync iota(500) with a fixed skip set" {
  const X = 6;
  const Q = 0x42;
  const allocator = std.heap.c_allocator;

  const n: u32 = 500;

  var skip = std.AutoHashMap(u32, bool).init(allocator);
  for (&[_]u32{ 81, 82, 83, 205, 210, 212, 409, 499 }) |x| {
    try skip.put(x, true);
  }

  try testSkipList(X, Q, n, &skip);
}

test "sync iota(10000) with a random skip set" {
  const X = 6;
  const Q = 0x42;

  const allocator = std.heap.c_allocator;

  const n: u32 = 10000;

  var prng = std.rand.DefaultPrng.init(0x0000000000000000);
  var random = prng.random();
  var skip = std.AutoHashMap(u32, bool).init(allocator);
  var i: u32 = 0;
  while (i < 100) : (i += 1) {
    var r = random.uintLessThan(u32, n);
    const limit = r + random.uintLessThan(u32, 10);
    while (r < limit) : (r += 1) {
      try skip.put(r, true);
    }
  }

  try testSkipList(X, Q, n, &skip);
}

test "sync iota(10000) with a single missing element" {
  const X = 6;
  const Q = 0x42;

  const allocator = std.heap.c_allocator;

  const n: u32 = 10000;

  var prng = std.rand.DefaultPrng.init(0x0000000000000000);
  var random = prng.random();
  var skip = std.AutoHashMap(u32, bool).init(allocator);
  var r = random.uintLessThan(u32, n);
  try skip.put(r, true);

  try testSkipList(X, Q, n, &skip);
}

fn testSkipList(comptime X: usize, comptime Q: u8, n: u32, skip: *std.AutoHashMap(u32, bool)) !void {
  const Node = okra.Node(X);
  const Tree = okra.Tree(X, Q);
  const allocator = std.heap.c_allocator;

  std.debug.print("\n", .{});

  var tmp = std.testing.tmpDir(.{});
  defer tmp.cleanup();

  const sourcePath = try utils.resolvePath(allocator, tmp.dir, "source.mdb");
  defer allocator.free(sourcePath);

  const targetPath = try utils.resolvePath(allocator, tmp.dir, "target.mdb");
  defer allocator.free(targetPath);

  var source: Tree = undefined;
  try source.init(allocator, sourcePath, .{ });
  defer source.close();

  var target: Tree = undefined;
  try target.init(allocator, targetPath, .{ });
  defer target.close();

  std.log.warn("Skip list has {d} elements", .{ skip.count() });
  try iota(X, Q, &source, n, null);
  try iota(X, Q, &target, n, skip);

  var leaves = std.ArrayList(Node).init(allocator);

  var driver: Driver(X, Q) = undefined;
  try driver.init(allocator, &target, &source);
  defer driver.close();

  try driver.exec(&leaves);

  try expect(leaves.items.len == skip.count());
  for (leaves.items) |node| {
    const v = std.mem.readIntBig(u32, node.leaf[X-4..]);
    try expect(skip.contains(v - 1));
  }

  std.log.warn("CALLS: {d}", .{ driver.calls });
}

fn iota(comptime X: usize, comptime Q: u8, tree: *okra.Tree(X, Q), n: u32, skip: ?*std.AutoHashMap(u32, bool)) !void {
  var leaf = [_]u8{ 0 } ** X;
  var hash = [_]u8{ 0 } ** 32;

  var i: u32 = 0;
  while (i < n) : (i += 1) {
    if (skip) |map| if (map.contains(i)) continue;

    std.mem.writeIntBig(u32, leaf[X-4..], i + 1);
    Sha256.hash(&leaf, &hash, .{});
    // std.log.warn("inserting {s} -> {s}", .{ hex(&leaf), hex(&hash) });
    try tree.insert(&leaf, &hash);
  }
}