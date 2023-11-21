# API

## Table of Contents

- [Tree](#tree)
- [Node](#node)
- [Iterator](#iterator)

The two basic classes are `Tree` and `Iterator`. Internally, they're generic structs parametrized by two comptime values `K: u8` and `Q: u32`:

- `K` is the size **in bytes** of the internal Blake3 hash digests.
- `Q` is the target fanout degree. Nodes in a tree will have, on average, `Q` children.

The concrete structs exported from [src/lib.zig](src/lib.zig) use the recommended values **`K = 16`** and **`Q = 32`**.

Trees expose a classical key/value store interface with `get`, `set`, and `delete` methods. Iterators are used to iterate over ranges of nodes within the tree. Ranges are always on a single level of the tree, and have optional upper/lower inclusive/exclusive key bounds.

## Tree

```zig
const lmdb = @import("lmdb");

const Tree = struct {
    pub const Options = struct {
        log: ?std.fs.File.Writer = null,
        trace: ?*NodeList = null,
        effects: ?*Effects = null,
    };

    pub fn open(
        allocator: std.mem.Allocator,
        txn: lmdb.Transaction,
        dbi: lmdb.Transaction.DBI,
        options: Options,
    ) !Tree

    pub fn close(self: *Tree) void
}
```

Trees are initialized with an LMDB transaction and database ID. They must be closed by calling `tree.close()` **before** the LMDB transaction is committed or aborted. Unfortunately, there's no way to detect this case or handle it gracefully due to how cursors work in LMDB.

> ⚠️ Failing to close the tree before committing or aborting the transaction WILL crash your code.

An easy way to make sure this happens is to always open trees within their own block.

```zig
var dir = std.fs.cwd().openDir("db", .{});
defer dir.close();

const env = try lmdb.Environment.open(dir, .{});
defer env.close();

const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadWrite });
errdefer txn.abort();

const dbi = try txn.openDatabase(null, .{});

// scope the tree to its own block so that
// it closes before the transaction commits
{
    var tree = try okra.Tree.open(txn, dbi, .{});
    defer tree.close();

    try tree.set("a", "foo");
    try tree.set("b", "bar");
    // ...
}

try txn.commit();
```

See the [zig-lmdb repo](https://github.com/canvasxyz/zig-lmdb) for documentation on LMDB environments, transactions, and database IDs.

## Node

```zig
pub const Node = struct {
    level: u8,
    key: ?[]const u8,
    hash: *const [K]u8,
    value: ?[]const u8,

    pub fn isBoundary(self: Node) bool
    pub fn equal(self: Node, other: Node) bool
};
```

The iterator methods return `Node` structs, which represent internal nodes of the merkle tree. Leaf nodes have level `0`. `node.key` is `null` for anchor nodes. `node.value` is null if `node.key == null` or `node.level > 0` (anchor or non-leaf nodes), and points to the value of the leaf entry if `node.key != null` and `node.level == 0` (non-anchor leaf nodes).

## Iterator

```zig
pub const Iterator = struct {
    pub const Bound = struct { key: ?[]const u8, inclusive: bool };
    pub const Range = struct {
        level: u8,
        lower_bound: ?Bound = null,
        upper_bound: ?Bound = null,
        reverse: bool = false,
    };

    pub fn open(
        allocator: std.mem.Allocator,
        txn: lmdb.Transaction,
        dbi: lmdb.Transaction.DBI,
        range: Range,
    ) !Iterator

    pub fn close(self: *Iterator) void
    pub fn reset(self: *Iterator, range: Range) !void

    pub fn next(self: *Self) !?Node
}
```

```zig
var dir = std.fs.cwd().openDir("db", .{});
defer dir.close();

const env = try lmdb.Environment.open(dir, .{});
defer env.close();

const txn = try lmdb.Transaction.open(env, .{ .mode = .ReadOnly });
defer txn.abort();

const dbi = try txn.openDatabase(null, .{});

{
    var tree = try okra.Tree.open(txn, dbi, .{});
    defer tree.close();

    var iterator = try Iterator.open(allocator, &txn, .{ .level = 0 });
    defer iterator.close();

    while (try iterator.next()) |node| {
        // ...
    }
}
```

Iterators must be closed before its LMDB transaction is aborted or committed. The iterator yields a `node: Node`, whose fields `key`, `hash`, and `value` are only valid until the next yield.
