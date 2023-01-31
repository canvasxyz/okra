```
          oooo                            
          `888                            
 .ooooo.   888  oooo  oooo d8b  .oooo.    
d88' `88b  888 .8P'   `888""8P `P  )88b   
888   888  888888.     888      .oP"888   
888   888  888 `88b.   888     d8(  888   
`Y8bod8P' o888o o888o d888b    `Y888""8o  
```

okra is a _merkle skip list_ written in Zig and built on LMDB. It can be used via C headers or the NodeJS bindings published as `node-okra` on NPM.

You can use okra as a persistent key/value store, with a special skip list structure and cursor interface that **enables a new class of efficient p2p syncing algorithms**. For example, if you have a peer-to-peer network in which peers publish CRDT operations but occasionally go offline and miss operations, two peers can use okra to **quickly identify missing operations** without relying on any type of consensus, ordering, vector clocks, etc. This is fast even if the database of operations is extremely large and the differences are buried deep in the past.

## Table of Contents

- [Design](#design)
- [API](#API)
- [Benchmarks](#benchmarks)
- [References](#references)
- [Contributing](#contributing)
- [License](#license)

## Design

okra is a [merkle tree](https://en.wikipedia.org/wiki/Merkle_tree) whose leaves are key/value entries sorted lexicographically by key. It has three crucial properties:

1. deterministic: two trees have the same root hash if and only if they comprise the same set of leaf entries, independent of insertion order
2. pseudorandom: the number of children per node varies, but the expected degree is a constant and can be configured by the user
3. robust: adding/removing/changing an entry only changes log(N) other nodes

Here's a diagram of an example tree. Arrows are drawn vertically for the first child and horizontally between siblings, instead of diagonally for every child.

```
            ╔════╗                                                                                                                                            
 level 4    ║root║                                                                                                                                            
            ╚════╝                                                                                                                                            
              │                                                                                                                                               
              ▼                                                                                                                                               
            ╔════╗                                                               ┌─────┐                                                                      
 level 3    ║null║ ─────────────────────────────────────────────────────────────▶│  g  │                                                                      
            ╚════╝                                                               └─────┘                                                                      
              │                                                                     │                                                                         
              ▼                                                                     ▼                                                                         
            ╔════╗                                                               ╔═════╗                                                     ┌─────┐          
 level 2    ║null║ ─────────────────────────────────────────────────────────────▶║  g  ║   ─────────────────────────────────────────────────▶│  m  │          
            ╚════╝                                                               ╚═════╝                                                     └─────┘          
              │                                                                     │                                                           │             
              ▼                                                                     ▼                                                           ▼             
            ╔════╗             ┌─────┐   ┌─────┐                                 ╔═════╗             ┌─────┐                                 ╔═════╗          
 level 1    ║null║────────────▶│  b  │──▶│  c  │────────────────────────────────▶║  g  ║────────────▶│  i  │────────────────────────────────▶║  m  ║          
            ╚════╝             └─────┘   └─────┘                                 ╚═════╝             └─────┘                                 ╚═════╝          
              │                   │         │                                       │                   │                                       │             
              ▼                   ▼         ▼                                       ▼                   ▼                                       ▼             
            ╔════╗   ┌─────┐   ╔═════╗   ╔═════╗   ┌─────┐   ┌─────┐   ┌─────┐   ╔═════╗   ┌─────┐   ╔═════╗   ┌─────┐   ┌─────┐   ┌─────┐   ╔═════╗   ┌─────┐
 level 0    ║null║──▶│a:foo│──▶║b:bar║──▶║c:baz║──▶│d:...│──▶│e:...│──▶│f:...│──▶║g:...║──▶│h:...│──▶║i:...║──▶│j:...│──▶│k:...│──▶│l:...│──▶║m:...║──▶│n:...│
            ╚════╝   └─────┘   ╚═════╝   ╚═════╝   └─────┘   └─────┘   └─────┘   ╚═════╝   └─────┘   ╚═════╝   └─────┘   └─────┘   └─────┘   ╚═════╝   └─────┘
```

The key/value entries are the leaves of the tree (level 0), sorted lexicographically by key. Each level begins with an initial _anchor node_ labelled "null", and the rest are labelled with the key of their first child.

Every node, including the leaves and the anchor nodes of each level, stores a Blake3 hash. The leaves hash their key/value entry, and nodes of higher levels hash the concatenation of their children's hashes. As a special case, the anchor leaf stores the hash of the empty string `Blake3() = af1349b9...`. For example, the hash value for the anchor node at `(1, null)` would be `Blake3(Blake3(), hashEntry("a", "foo"))` since `(0, null)` and `(0, "a")` are its only children. `hashEntry` is implemented like this:

```zig
fn hashEntry(key: []const u8, value: []const u8, result: []u8) void {
    var digest = Blake3.init(.{});
    var size: [4]u8 = undefined;
    std.mem.writeIntBig(u32, &size, @intCast(u32, key.len));
    digest.update(&size);
    digest.update(key);
    std.mem.writeIntBig(u32, &size, @intCast(u32, value.len));
    digest.update(&size);
    digest.update(value);
    digest.final(result);
}
```

Since the structure of the tree must be a pure function of the entries, it's easiest to imagine building the tree up layer by layer from the leaves. For a tree with a target fanout degree of `Q`, the rule for building layer `N+1` is to promote nodes from layer `N` whose **first four hash bytes** read as a big-endian `u32` is less than `2^^32 / Q` (integer division rounding towards 0). The anchor nodes of each layer are always promoted. In the diagram, nodes with `u32(node.hash[0..4]) < 2^^32 / Q` are indicated with double borders.

In practice, the tree is incrementally maintained and is not re-built from the ground up on every change. Updates are O(log(N)).

The tree is stored in an LMDB database where nodes are _LMDB_ key/value entries with keys prefixed by a `level: u8` byte and values prefixed by the entry's `[K]u8` hash. For anchor nodes, the level byte is the entire key, and for non-leaf `level > 0` nodes, the hash is the entire value. The key `[1]u8{0xFF}` is reserved as a metadata entry for storing the database version and compile-time constants. This gives the tree a maximum height of 254. In practice, with the default fanout degree of 32, the tree will rarely be taller than 5 (millions of entries) or 6 (billions of entries) levels.

<!-- This approach is different than e.g. Dolt's Prolly Tree implementation, which is a from-scratch b-tree that reads and writes its own pages and is used as the foundation of a full-blown relational database. okra is designed to be used as a simple efficiently-diffable key/value store, and leverages LMDB to reduce the implementation to just the logical rebalancing operations and inhert all its ACID transaction properties.

Another point worth mentioning is that embracing a two-level approach (building the MST on top of a key/value store) changes the incentives around picking a fanout degree probability distribution function (PDF). Our naive `u32(node.hash[0..4]) < 2^^32 / Q` condition produces a geometric distribution of degrees (asymmetrically more smaller values than larger values). This is bad for a low-level b-tree where you want as consistenly-sized chunks as possible, so Dolt weights their rolling hash function to produce a PDF symmetric around the expected value. But in okra, the boundaries between the children of different nodes are just conceptual, and the underlying pages in the LMDB database can end up spanning several conceptual nodes, or vice versa. To be clear, this doesn't mean that the geometric distribution is preferable or that okra is more performant, just that it enjoys a clean separation of concerns by building on a key/value abstraction. -->

okra has no external concept of versioning or time-travel. LMDB is copy-on-write, and open transactions retain a consistent view of a snapshot of the database, but the old pages are garbage-collected once the last transaction referencing them is closed. When we talk about "comparing two merkle roots", we mean two separate database instances (e.g. on different machines), not two local revisions of the same database.

## API

The three basic classes are `Tree`, `Transaction`, and `Cursor`. Internally, all three are generic structs parametrized by two comptime values `K: u8` and `Q: u32`:

- `K` is the size **in bytes** of the internal Blake3 hash digests.
- `Q` is the target fanout degree. Nodes in a tree will have, on average, `Q` children.

Concrete structs are exported from [src/lib.zig](src/lib.zig) with the default values **`K = 16`** and **`Q = 32`**.

Trees and transactions form a classical key/value store interface. You can open a tree, use the tree to open read-only or read-write transactions, and use the transaction to get, set, and delete key/value entries.

A cursor can be used to move around the nodes of the tree itself, which includes the leaves, the intermediate-level nodes, and the root node.

### Tree

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

### Transaction

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

### Cursor

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

## Benchmarks

See [BENCHMARKS.md](./BENCHMARKS.md).

## References 

- https://hal.inria.fr/hal-02303490/document
- https://0fps.net/2020/12/19/peer-to-peer-ordered-search-indexes/
- https://www.dolthub.com/blog/2020-04-01-how-dolt-stores-table-data/
- https://www.dolthub.com/blog/2022-06-27-prolly-chunker/
- https://github.com/attic-labs/noms/blob/master/doc/intro.md#prolly-trees-probabilistic-b-trees

## Contributing

If you find a bug, have suggestions for better interfaces, or would like to add more tests, please open an issue to discuss it!

## License

MIT © 2023 Canvas Technology Corporation
