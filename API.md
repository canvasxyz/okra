# API

## Table of Contents

- [Store](#store)
- [Index](#store)
- [Node](#node)
- [Iterator](#iterator)

The basic classes are `Store`, `Index`, and `Iterator`. Internally, they're generic structs parametrized by two comptime values `K: u8` and `Q: u32`:

- `K` is the size **in bytes** of the internal Blake3 hash digests.
- `Q` is the target fanout degree. Nodes in the internal merkle tree will have, on average, `Q` children.

The concrete structs exported from [src/lib.zig](src/lib.zig) use the recommended values **`K = 16`** and **`Q = 32`**.

Both `Store` and `Index` are thin wrappers over an internal `Tree` struct:

- A `Store` exposes a classical key/value store interface with `get(key)`, `set(key, value)`, and `delete(key)` methods.
- An `Index` only stores 16-byte Blake3 hashes on the leaf nodes, with no additional `value` bytes.

Use an `Iterator` to iterate over ranges of nodes within the tree. Ranges are always on a single level of the tree, and have optional upper/lower inclusive/exclusive key bounds.

## Store

```zig
const lmdb = @import("lmdb");

const Store = struct {
    pub const Options = struct {
        log: ?std.fs.File.Writer = null,
    };

    pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, options: Options) !Store
    pub fn deinit(self: *Store) void

    pub fn get(self: *Store, key: []const u8) !?[]const u8
    pub fn set(self: *Store, key: []const u8, value: []const u8) !void
    pub fn delete(self: *Store, key: []const u8) !void

    pub fn getRoot(self: *Store) !Node
    pub fn getNode(self: *Store, level: u8, key: ?[]const u8) !?Node
}
```

Store instances are initialized with an LMDB database. They must be closed by calling `store.deinit()` before the LMDB transaction is committed or aborted

> See the [zig-lmdb repo](https://github.com/canvasxyz/zig-lmdb) for documentation on LMDB environments, transactions, and databases.

## Index

```zig
const lmdb = @import("lmdb");

const Index = struct {
    pub const Options = struct {
        log: ?std.fs.File.Writer = null,
    };

    pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, options: Options) !Index
    pub fn deinit(self: *Index) void

    pub fn get(self: *Index, key: []const u8) !?*const [16]u8
    pub fn set(self: *Index, key: []const u8, hash: *const [16]u8) !void
    pub fn delete(self: *Index, key: []const u8) !void

    pub fn getRoot(self: *Index) !Node
    pub fn getNode(self: *Index, level: u8, key: ?[]const u8) !?Node
}
```

Just like Stores, Index instances are initialized with an LMDB database. They must be closed by calling `index.deinit()` before the LMDB transaction is committed or aborted.

> See the [zig-lmdb repo](https://github.com/canvasxyz/zig-lmdb) for documentation on LMDB environments, transactions, and databases.

## Node

```zig
pub const Node = struct {
    level: u8,
    key: ?[]const u8,
    hash: *const [K]u8,
    value: ?[]const u8,

    pub fn isBoundary(self: Self) bool
    pub fn isAnchor(self: Self) bool
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

    pub fn init(allocator: std.mem.Allocator, db: lmdb.Database, range: Range) !Iterator
    pub fn deinit(self: *Iterator) void

    pub fn next(self: *Self) !?Node
    pub fn reset(self: *Iterator, range: Range) !void
}
```

```zig
const env = try lmdb.Environment.init("path/to/db", .{});
defer env.deinit();

const txn = try env.transaction(.{ .mode = .ReadOnly });
defer txn.abort();

const db = try txn.database(null, .{});

var store = try okra.Store.init(db, .{});
defer store.deinit();

var iterator = try Iterator.init(allocator, db, .{ .level = 0 });
defer iterator.deinit();

while (try iterator.next()) |node| {
    // ...
}
```

Iterators must also be closed before its LMDB transaction is aborted or committed. The iterator yields `Node` values whose fields `key`, `hash`, and `value` are only valid until the next yield.
