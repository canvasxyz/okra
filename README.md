```
          oooo                            
          `888                            
 .ooooo.   888  oooo  oooo d8b  .oooo.    
d88' `88b  888 .8P'   `888""8P `P  )88b   
888   888  888888.     888      .oP"888   
888   888  888 `88b.   888     d8(  888   
`Y8bod8P' o888o o888o d888b    `Y888""8o  
```

okra is a merkle search tree written in Zig and built on LMDB.

You can use okra as a persistent key/value store with efficient p2p syncing built-in: two okra instances (e.g. peers on a mesh network) can **quickly identify missing or conflicting entries**. It's like O(log(N)) rsync for LMDB.

## Table of Contents

- [API](#API)
- [Internal design](#internal-design)
- [Use cases](#use-cases)
- [References](#references)
- [Contributing](#contributing)
- [License](#license)

## API

The four basic classes are `Tree`, `Transaction`, `Iterator`, and `Cursor`. All four are parametrized by two comptime `u8` values `Q` and `K`:

- `Q` is the target fanout degree. Nodes in a tree `Tree(Q, K)` will have, on average, `Q` children. It must be greater than 1 and less than 256. `32` is a sensible default.
- `K` is the size **in bytes** of the Blake3 hash digest used internally. `32` is the maximum value; `16` is a sensible default.

Trees and transactions form a classical key/value store interface. You can open a tree, use the tree to open read-only or read-write transactions, and use the transaction to get, set, and delete key/value entries.

Iterators are cursor are similar but operate on different abstractions: an iterator iterates of the entries of the abstract key/value store (which are, in reality, just the leaves of the tree), while a cursor is used to move around the nodes of the tree itself (which includes the leaves, the intermediate-level nodes, and the root node).

### Tree

A `Tree` is the basic database connection handle and wraps an LMDB environment.

```zig
/// Tree(comptime Q: u8, comptime K: u8)
struct {
    const Self = @This();

    pub const Options = struct { map_size: usize = 10485760 };

    pub fn open(allocator: std.mem.Allocator, path: [:0]u8, options: Options) !*Self
    pub fn close(self: *Self) void
}
```

`Tree(Q, K).open(allocator, path)` returns a pointer `*Tree(Q, K)` to a new tree allocated using the provided allocator; `tree.close()` frees the tree and all its associated resources.

### Transaction

Given a tree `tree: Tree(Q, K)`, you can open a transaction with `Transaction(Q, K).open(allocator, tree, .{ .read_only = read_only })`. This allocators and returns a `*Transaction(Q, K)` which must be freed by calling either `.abort` (read-only or read-write transactions) or `.commit` (read-write transactions only).

```zig
/// Transaction(comptime Q: u8, comptime K: u8)
struct {
    const Self = @This();

    pub const Options = struct { read_only: bool, log: ?std.fs.File.Writer = null };
    
    pub fn open(allocator: std.mem.Allocator, tree: *const Tree(Q, K), options: Options) !*Self
    pub fn abort(self: *Self) void
    pub fn commit(self: *Self) !void

    pub fn get(self: *Self, key: []const u8) !?[]const u8
    pub fn set(self: *Self, key: []const u8, value: []const u8) !void
    pub fn delete(self: *Self, key: []const u8) !void
}
```

### Iterator

You can open an iterator to iterate over the entries in lexicographic key order and to seek by key prefix ranges. okra inherits its transactional semantics from LMDB; transactions are multi-reader and single-writer (ie only one write transaction open at a time).

Iterators must be freed by calling `iterator.close()`.

```zig
/// Iterator(comptime Q: u8, comptime K: u8)
struct {
    const Self = @This();

    pub const Entry = struct { key: []const u8, value: []const u8 };
    
    pub fn open(allocator: std.mem.Allocator, txn: *const Transaction(Q, K)) !*Self
    pub fn close(self: *Self) void

    pub fn goToFirst(self: *Self) !?Entry
    pub fn goToLast(self: *Self) !?Entry
    pub fn goToNext(self: *Self) !?Entry
    pub fn goToPrevious(self: *Self) !?Entry
    pub fn seek(self: *Self, key: []const u8) !?Entry
}
```

### Cursor

```zig
/// Cursor(comptime Q: u8, comptime K: u8)
struct {
    const Self = @This();

    pub const Node = struct { level: u8, key: ?[]const u8, hash: *const [K]u8 };

    pub fn open(allocator: std.mem.Allocator, txn: *const Transaction(Q, K)) !*Self
    pub fn close(self: *Self) void

    pub fn goToRoot(self: *Self) !Node
    pub fn goToNode(self: *Self, level: u8, key: ?[]const u8) !Node
    pub fn goToNext(self: *Self) !?Node
    pub fn goToPrevious(self: *Self) !?Node
    pub fn seek(self: *Self, level: u8, key: ?[]const u8) !?Node
}
```

## Internal design

okra is a [merkle tree](https://en.wikipedia.org/wiki/Merkle_tree) with three crucial properties:

1. deterministic: two trees have the same root hash if and only if they comprise the same set of entries, independent of insertion order
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

The entries of the conceptual key/value store are the leaves of the tree, at level 0, sorted lexicographically by key. Each level begins with an initial "null" node (not part of the public key/value interface), and the rest are named with the key of their first child.

Every node, including the leaves and the null nodes of each level, stores a Sha2-256 hash. The leaves hash their entry's value, and nodes of higher levels hash the concatenation of their children's hashes. As a special case, the null leaf stores the Sha256 of the empty string `Sha256() = e3b0c44...`. For example, the hash value for the node at `(1, null)` would be `Sha256(Sha256(), Sha256("foo"))` since `(0, null)` and `(0, "a")` are its only children.

Since the structure of the tree must be a pure function of the entries, it's easiest to imagine building the tree up layer by layer from the leaves. For a tree with a target fanout degree of `Q`, the rule for building layer `N+1` is to promote nodes from layer `N` whose **last hash byte** (`hash[K]`) is less than `256 / Q` (integer division rounding towards 0). The initial null nodes of each layer are always promoted. In the diagram, nodes with `node.hash[K] < 256 / Q` are indicated with double borders.

In practice, the tree is incrementally maintained and is not re-built from the ground up on every change. Updates are O(log(N)).

The tree is stored in an LMDB database where nodes are _LMDB_ key/value entries with keys prefixed by a `level: u8` byte and values prefixed by the `hash: [K]u8`. For null node entries, the level byte is the entire key, and for non-leaf `level > 0` node entries, the hash is the entire value. The key `[1]u8{ 0xFF }` is reserved as a metadata entry for storing the database version, database variant, and height of the tree. This gives the tree a maximum height of 254. In practice, with the default fanout degree of 32, the tree will rarely be taller than 5 (millions of entries) or 6 (billions of entries) levels.

This approach is different than e.g. Dolt's Prolly Tree implementation, which is a from-scratch b-tree that reads and writes its own pages and is used as the foundation of a full-blown relational database. okra is designed to be used as a simple efficiently-diffable key/value store, and leverages LMDB to reduce the implementation to just the logical rebalancing operations and inhert all its ACID transaction properties.

Another point worth mentioning is that embracing a two-level approach (building the MST on top of a key/value store) changes the incentives around picking a fanout degree probability distribution function (PDF). Our naive `node.hash[K] < 256 / Q` condition produces a geometric distribution of degrees (asymmetrically more smaller values than larger values). This is bad for a low-level b-tree where you want as consistenly-sized chunks as possible, so Dolt weights their rolling hash function to produce a PDF symmetric around the expected value. But in okra, the boundaries between the children of different nodes are just conceptual, and the underlying pages in the LMDB database can end up spanning several conceptual nodes, or vice versa. To be clear, this doesn't mean that the geometric distribution is preferable or that okra is more performant, just that it enjoys a clean separation of concerns by building on a key/value abstraction.

okra has no external concept of versioning or time-travel. LMDB is copy-on-write, and open transactions retain a consistent view of a snapshot of the database, but the old pages are garbage-collected once the last transaction referencing them is closed. When we talk about "comparing two merkle roots", we mean two separate database instances (e.g. on different machines), not two local revisions of the same database.

## Use cases

okra is good for things like pulling in updates from a single of truth (uni-directional), or storing CRDT operations or serving as a general persistence layer for decentralized pubsub messages (grow-only).

Its major limitation is that if you try to use it directly as a general p2p key/value store, it's impossible to tell whether a given entry has been deleted, or was just never seen in the first place. Of course, you can still implement this yourself by storing vector clock timestamps in every entry and keeping deleted tombstones around. This "roll-your-own-concept-of-deletion" rigmarole is what every CRDT map implementation has to do anyway.

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