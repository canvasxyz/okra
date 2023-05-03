# API

## Table of Contents

- [Tree](#tree)
- [Transaction](#transaction)
- [Iterator](#iterator)


The three basic classes are `Tree`, `Transaction`, and `Iterator`. Internally, all three are generic structs parametrized by two comptime values `K: u8` and `Q: u32`:

- `K` is the size **in bytes** of the internal Blake3 hash digests.
- `Q` is the target fanout degree. Nodes in a tree will have, on average, `Q` children.

Concrete structs are exported from [src/lib.zig](src/lib.zig) with the default values **`K = 16`** and **`Q = 32`**.

Trees and transactions form a classical key/value store interface. You can open a tree, use the tree to open read-only or read-write transactions, and use the transaction to get, set, and delete key/value entries.

An iterator can be used to iterate over ranges of merkle nodes in the tree itself. Ranges are always on a single level of the tree, and have optional upper/lower inclusive/exclusive key bounds.

## Tree

```zig
const Tree = struct {
    pub const Options = struct { map_size: usize = 10485760, dbs: ?[]const [*:0]const u8 = null };

    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !Tree
    pub fn init(self: *Tree, allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void
    pub fn close(self: *Tree) void
}
```

A `Tree` is the basic database connection handle and wraps an LMDB environment. It can be allocated on the stack or the heap, and must be closed by calling `tree.close()`.

The `path` must be an absolute path to a directory. `Tree.init` / `Tree.open` will create the directory if it does not exist.

```zig
// allocate on the stack
var tree = try Tree.open("/path/to/data.okra", .{});
defer tree.close();
```

```zig
// allocate on the heap
const tree = try allocator.create(Tree);
defer allocator.destroy(tree);
try tree.init(allocator, "/path/to/data.okra", .{});
defer tree.close();
```

The `map_size` parameter is forwarded to the underlying LMDB environment. From [the LMDB docs](http://www.lmdb.tech/doc/group__mdb.html#gaa2506ec8dab3d969b0e609cd82e619e5):

> The size should be a multiple of the OS page size. The default is 10485760 bytes. The size of the memory map is also the maximum size of the database. The value should be chosen as large as possible, to accommodate future growth of the database.

LMDB has optional support for multiple [named databases](http://www.lmdb.tech/doc/group__mdb.html#gac08cad5b096925642ca359a6d6f0562a) (called "DBI handles") within a single LMDB environment. By default, okra trees interact with the single default LMDB DBI. You can opt in to using isolated named DBIs by passing a slice of `[*:0]const u8` names in `Tree.Options.dbs`, and selecting a specific DBI with `Transaction.Options.dbi` with every transaction. Note that **these two modes are exclusive**: if `Tree.Options.dbs == null`, then every `Transaction.Options.dbi` must also be null, and if `Tree.Options.dbs != null` then every `Transaction.Options.dbi` must be one of the values in `Tree.Options.dbs`.

## Node

```zig
pub const Node = struct {
    level: u8,
    key: ?[]const u8,
    hash: *const [K]u8,
    value: ?[]const u8,

    pub fn isBoundary(self: Node) bool
    pub fn equal(self: Node, other: Node) bool
    pub fn parse(key: []const u8, value: []const u8) !Node
};
```

Some transaction and iterator methods return `Node` structs, which represent internal nodes of the merkle tree. Leaf nodes have level `0`. `node.key` is `null` for anchor nodes. `node.value` is null if `node.knodesey == null` or `node.level > 0` (anchor or non-leaf nodes), and points to the value of the leaf entry if `node.key != null` and `node.level == 0` (non-anchor leaf nodes).

## Transaction

```zig
const Transaction = struct {
    pub const Options = struct { read_only: bool, dbi: ?[*:0]const u8 = null, log: ?std.fs.File.Writer = null };
    
    // lifecycle methods
    pub fn open(allocator: std.mem.Allocator, tree: *const Tree, options: Options) !Transaction
    pub fn abort(self: *Transaction) void
    pub fn commit(self: *Transaction) !void

    // get, set, and delete key/value entries
    pub fn get(self: *Transaction, key: []const u8) !?[]const u8
    pub fn set(self: *Transaction, key: []const u8, value: []const u8) !void
    pub fn delete(self: *Transaction, key: []const u8) !void

    pub fn getRoot(self: *Transaction) !Node
    pub fn getNode(self: *Transaction, level: u8, key: ?[]const u8) !?Node
}
```

A `Transaction` can be read-only or read-write. Only one write transaction can be open at a time. 

```zig
// read-only transaction
var tree = try Tree.open(allocator, "/path/to/db.okra", .{});
defer tree.close();

{
    var txn = try Transaction.open(allocator, &tree, .{ .read_only = true });
    defer txn.abort();

    const value = try txn.get("foo");
}
```

```zig
var tree = try Tree.open(allocator, "/path/to/db.okra", .{});
defer tree.close();

{
    var txn = try Transaction.open(allocator, &tree, .{ .read_only = false });
    errdefer txn.abort();

    try txn.set("a", "foo");
    try txn.delete("b");
    // ...

    try txn.commit();
}
```

Read-only transactions must be closed by calling `.abort()`, and read-write transactions must be closed by either calling `.abort()` or `.commit()`. Zig [blocks](https://ziglang.org/documentation/master/#Blocks) are useful for controlling the scope of deferred aborts. For read-write transactions, you want to `errdefer txn.abort()` immediately after opening the transaction and call `try txn.commit()` as the last statement of the block.

Just like trees, a heap-allocated transaction can be initialized with `.init()`:

```zig
// allocate on the heap
const tree = try allocator.create(Tree);
defer allocator.destroy(txn);
try tree.init(allocator, "/path/to/db.okra", .{});
defer tree.close();

const txn = try allocator.create(Transaction);
defer allocator.destroy(txn);
try txn.init(allocator, tree, .{ .read_only = false });
defer txn.abort();

const value = try txn.get("foo");
```

If the environment was opened with a positive `options.max_dbs`, you can open a transaction inside an isolated named database by passing an `Options.dbi: [*:0]const u8` name.

## Iterator

```zig
pub const Iterator = struct {
    pub const Bound = struct { key: ?[]const u8, inclusive: bool };
    pub const Range = struct {
        level: u8 = 0,
        lower_bound: ?Bound = null,
        upper_bound: ?Bound = null,
        reverse: bool = false,
    };

    pub fn open(allocator: std.mem.Allocator, txn: *const Transaction, range: Range) !Iterator
    pub fn init(self: *Iterator, allocator: std.mem.Allocator, txn: *const Transaction, range: Range) !void

    pub fn close(self: *Iterator) void
    pub fn reset(self: *Iterator, range: Range) !void

    pub fn next(self: *Self) !?Node
}
```

Just like trees and transactions, iterators can be allocated on the stack:

```zig
var tree = try Tree.open(allocator, "/path/to/okra.db", .{});
var txn = try Transaction.open(allocator, &tree, .{ .read_only = true });
defer txn.abort();

var iterator = try Iterator.open(allocator, &txn, .{ .level = 0 });
defer iterator.close();

while (try iterator.next()) |node| {
    // ...
}
```

... or the heap:

```zig
// allocate on the heap
const tree = try allocator.create(Tree);
defer allocator.destroy(txn);
try tree.init(allocator, "/path/to/db.okra", .{});
defer tree.close();

const txn = try allocator.create(Transaction);
defer allocator.destroy(txn);
try txn.init(allocator, tree, .{ .read_only = false });
defer txn.abort();

const iterator = try allocator.create(Iterator);
defer allocator.destroy(iterator);
try iterator.init(allocator, txn, .{ .level = 0 });
defer iterator.close();

while (try iterator.next()) |node| {
    // ...
}
```

Iterators must be closed before their parent transaction is aborted or committed. The iterator yields a `Node`, whose fields `key`, `hash`, and `value` are only valid until the next yield.