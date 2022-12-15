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

Since the structure of the tree must be a pure function of the entries, it's easiest to imagine building the tree up layer by layer from the leaves. For a tree with a target fanout degree of `Q`, the rule for building layer `N+1` is to promote nodes from layer `N` whose **last hash byte** (`hash[31]`) is less than `256 / Q` (integer division rounding towards 0). The initial null nodes of each layer are always promoted. In the diagram, nodes with `node.hash[31] < 256 / Q` are indicated with double borders.

In practice, the tree is incrementally maintained and is not re-built from the ground up on every change. Updates are O(log(N)).

The tree is stored in an LMDB database where nodes are _LMDB_ key/value entries with keys prefixed by a `level: u8` byte and values prefixed by the `hash: [32]u8`. For null node entries, the level byte is the entire key, and for non-leaf `level > 0` node entries, the hash is the entire value. The key `[1]u8{ 0xFF }` is reserved as a metadata entry for storing the database version, database variant, and height of the tree. This gives the tree a maximum height of 254. In practice, with the default fanout degree of 32, the tree will rarely be taller than 5 (millions of entries) or 6 (billions of entries) levels.

This approach is different than e.g. Dolt's Prolly Tree implementation, which is a from-scratch b-tree that reads and writes its own pages and is used as the foundation of a full-blown relational database. okra is designed to be used as a simple efficiently-diffable key/value store, and leverages LMDB to reduce the implementation to just the logical rebalancing operations and inhert all its ACID transaction properties.

Another point worth mentioning is that embracing a two-level approach (building the MST on top of a key/value store) changes the incentives around picking a fanout degree probability distribution function (PDF). Our naive `node.hash[31] < 256 / Q` condition produces a geometric distribution of degrees (asymmetrically more smaller values than larger values). This is bad for a low-level b-tree where you want as consistenly-sized chunks as possible, so Dolt weights their rolling hash function to produce a PDF symmetric around the expected value. But in okra, the boundaries between the children of different nodes are just conceptual, and the underlying pages in the LMDB database can end up spanning several conceptual nodes, or vice versa. To be clear, this doesn't mean okra is more performant in any specific way, just that it enjoys a clean separation of concerns by building on a key/value abstraction.

okra has no external concept of versioning or time-travel. LMDB is copy-on-write, and open transactions retain a consistent view of a snapshot of the database, but the old blocks are garbage-collected once the last reference is closed. When we talk about "comparing two merkle roots", we mean two separate database instances (e.g. on different machines), not two local revisions of the same database.

## External interface

okra comes in four variants: `Set`, `Map`, `SetIndex`, and `MapIndex`. The variant is part of the database (persited in the metadata key) and cannot change. Each variant is different interface. They all have `open` and `init` methods that are friendly to allocating on the stack and the heap, respectively, and both must be closed with `close`. They all take the same `Options` parameter.

```zig
pub const Options = struct {
    degree: u8 = 32,
    map_size: usize = 10485760,
    log: ?std.fs.File.Writer,
};
```

### `Map`

This is a normal key/value store exposing `set(key, value)`, `get(key) -> value`, and `delete(key)` operations.

```zig
pub const Map = struct {
    pub const Transaction = struct {
        pub fn open(map: *const MapIndex, read_only: bool) !Transaction
        pub fn init(self: *Transaction, map: *const MapIndex, read_only: bool) !void

        pub fn commit(self: *Transaction) !void
        pub fn abort(self: *Transaction) void

        pub fn set(self: *Transaction, key: []const u8, value: []const u8, hash: ?*[32]u8) !void
        pub fn get(self: *Transaction, key: []const u8, hash: ?*[32]u8) !?[]const u8
        pub fn delete(self: *Transaction, key: []const u8) !void
    }

    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !Map
    pub fn init(self: *Map, allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void
    pub fn close(self: *Map) void
  }
}
```

`Map.Transaction.set` and `Map.Transaction.get` write the entry value's hash to the pointer if one is passed.

### `MapIndex`

If you just want to use okra as an *index* - storing arbitrary keys mapped to arbitrary hashes without storing the associated values - you can use `MapIndex` instead.

```zig
pub const MapIndex = struct {
    pub const Transaction = struct {
        pub fn open(map: *const MapIndex, read_only: bool) !Transaction
        pub fn init(self: *Transaction, map: *const MapIndex, read_only: bool) !void

        pub fn commit(self: *Transaction) !void
        pub fn abort(self: *Transaction) void
    
        pub fn set(self: *Transaction, key: []const u8, value: []const u8, hash: *const [32]u8) !void
        pub fn get(self: *Transaction, key: []const u8) !?*const [32]u8
        pub fn delete(self: *Transaction, key: []const u8) !void
    }

    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !MapIndex
    pub fn init(self: *MapIndex, allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void
    pub fn close(self: *MapIndex) void
  }
}
```

### `Set`

If you just want to store values by their hash - in other words, if every entry's key is already the Sha256 hash of its value - you can use `Set`, which has `add(value) -> hash` and `delete(hash)` operations.

```zig
pub const Set = struct {
    pub const Transaction = struct {
        pub fn open(set: *const Set, read_only: bool) !Transaction
        pub fn init(self: *Transaction, set: *const Set, read_only: bool) !void

        pub fn commit(self: *Transaction) !void
        pub fn abort(self: *Transaction) void

        pub fn add(self: *Set, value: []const u8, hash: ?*[32]u8) !void
        pub fn get(self: *Set, hash: *const [32]u8) !?[]const u8
        pub fn delete(self: *Set, hash: *const [32]u8) !void
    }

    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !Set
    pub fn init(self: *Set, allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void
    pub fn close(self: *Set) void
  }
}
```

`Set.Transaction.add` writes the resulting hash to the pointer if one is passed.

### `SetIndex`

Similarly, if you just want to use okra to persist a set of hashes, with no other keys or values, you can use `SetIndex`.

```zig
pub const SetIndex = struct {
    pub const Transaction = struct {
        pub fn open(set: *const SetIndex, read_only: bool) !Transaction
        pub fn init(self: *Transaction, set: *const SetIndex, read_only: bool) !void

        pub fn commit(self: *Transaction) !void
        pub fn abort(self: *Transaction) void

        pub fn add(self: *Transaction, hash: *const [32]u8) !void
        pub fn delete(self: *Transaction, hash: *const [32]u8) !void
    }

    pub const Cursor = SkipListCursor(Transaction);

    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !SetIndex
    pub fn init(self: *SetIndex, allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !void
    pub fn close(self: *SetIndex) void
  }
}
```

### Cursors

## Use cases

okra is good for things like pulling in updates from a single of truth (uni-directional), or storing CRDT operations or serving as a general persistence layer for decentralized pubsub messages (grow-only). Its major limitation is that if you try to use it directly as a general p2p key/value store, it's impossible to tell whether a given entry has been deleted, or was just never seen in the first place. Of course, you can still implement this yourself by storing vector clock timestamps in every entry and keeping deleted tombstones around, which is what every CRDT map implementation has to do anyway.

## References 

- https://hal.inria.fr/hal-02303490/document
- https://0fps.net/2020/12/19/peer-to-peer-ordered-search-indexes/
- https://www.dolthub.com/blog/2020-04-01-how-dolt-stores-table-data/
- https://www.dolthub.com/blog/2022-06-27-prolly-chunker/
- https://github.com/attic-labs/noms/blob/master/doc/intro.md#prolly-trees-probabilistic-b-trees
