# API

## Table of Contents

- [Tree](#tree)
- [Transaction](#transaction)
- [Cursor](#cursor)


The three basic classes are `Tree`, `Transaction`, and `Cursor`. Internally, all three are generic structs parametrized by two comptime values `K: u8` and `Q: u32`:

- `K` is the size **in bytes** of the internal Blake3 hash digests.
- `Q` is the target fanout degree. Nodes in a tree will have, on average, `Q` children.

Concrete structs are exported from [src/lib.zig](src/lib.zig) with the default values **`K = 16`** and **`Q = 32`**.

Trees and transactions form a classical key/value store interface. You can open a tree, use the tree to open read-only or read-write transactions, and use the transaction to get, set, and delete key/value entries.

A cursor can be used to move around the nodes of the tree itself, which includes the leaves, the intermediate-level nodes, and the root node.

## Tree

```zig
const Tree = struct {
    pub const Options = struct { map_size: usize = 10485760 };

    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !Tree
    pub fn init(self: *Tree, allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void
    pub fn close(self: *Tree) void
}
```

A `Tree` is the basic database connection handle and wraps an LMDB environment. It can be allocated on the stack or the heap, and must be closed by calling `tree.close()`.

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

## Transaction

```zig
const Transaction = struct {
    pub const Options = struct { read_only: bool, log: ?std.fs.File.Writer = null };
    
    // lifecycle methods
    pub fn open(allocator: std.mem.Allocator, tree: *const Tree, options: Options) !*Transaction
    pub fn abort(self: *Transaction) void
    pub fn commit(self: *Transaction) !void

    pub fn get(self: *Transaction, key: []const u8) !?[]const u8
    pub fn set(self: *Transaction, key: []const u8, value: []const u8) !void
    pub fn delete(self: *Transaction, key: []const u8) !void

    pub fn getRoot(self: *Transaction) !Node
    pub fn getNode(self: *Transaction, level: u8, key: ?[]const u8) !Node
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

## Cursor

```zig
pub const Node = struct {
    level: u8,
    key: ?[]const u8,
    hash: *const [K]u8,
    value: ?[]const u8,

    pub fn isSplit(self: Self) bool
};

pub const Cursor = struct {
    pub fn open(allocator: std.mem.Allocator, txn: *const Transaction) !Cursor
    pub fn init(self: *Cursor, allocator: std.mem.Allocator, txn: *const Transaction) !void
    pub fn close(self: *Cursor) void

    pub fn goToRoot(self: *Cursor) !Node
    pub fn goToNode(self: *Cursor, level: u8, key: ?[]const u8) !Node
    pub fn goToNext(self: *Cursor) !?Node
    pub fn goToPrevious(self: *Cursor) !?Node
    pub fn seek(self: *Cursor, level: u8, key: ?[]const u8) !?Node
}
```

Cursor methods return `Node` structs.  `node.key` is `null` for anchor nodes. `node.value` is null if `node.key == null` or `node.level > 0`, and points to the value of the leaf entry if `node.key != null` and `node.level == 0`.

Just like trees and transactions, cursors can be allocated on the stack:

```zig
var tree = try Tree.open(allocator, "/path/to/okra.db", .{});
var txn = try Transaction.open(allocator, &tree, .{ .read_only = true });
defer txn.abort();

var cursor = try Cursor.open(allocator, &txn);
defer cursor.close();
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

const cursor = try allocator.create(Cursor);
defer allocator.destroy(cursor);
try cursor.init(allocator, txn);
defer cursor.close();
```

Cursors must be closed before their parent transaction is aborted or committed. Cursor operations return a `Node`, whose fields `key`, `hash`, and `value` are **only valid until the next cursor operation**.