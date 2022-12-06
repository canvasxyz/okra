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

1. deterministic: two trees have the same root hash if and only if they have the same set of entries, independent of insertion order
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

The entries of the conceptual key/value store comprise the leaves of the tree, at level 0, sorted lexicographically by key. Each level begins with an an initial "null" node (not part of the public key/value interface), and the rest are named with the key of their first child.

Every node, including the leaves and the null nodes of each level, stores a Sha2-256 hash. The leaves hash their entry's value, and nodes of higher levels hash the concatenation of their children's hashes. As a special case, the null leaf stores the Sha256 of the empty string (`Sha256() = e3b0c44...`). For example, the hash value for the node at `(1, null)` would be `Sha256(Sha256(), Sha256("foo"))`.

Since the structure of the tree must be a pure function of the entries, it's easiest to imagine building the tree up layer by layer from the leaves. For a tree with a target fanout degree of `Q`, the rule for building layer `N+1` is to promote nodes from layer `N` whose **last hash byte** (`hash[31]`) is less than `256 / Q` (integer division rounding towards 0). The initial null nodes of each layer are always promoted. In the diagram, nodes with `node.hash[31] < 256 / Q` are indicated with double borders.

In practice, the tree is incrementally maintained and is not re-built from the ground up on every change. Updates are O(log(N)).

The tree is stored in an LMDB database where nodes are _LMDB_ key/value entries with keys prefixed by a `level: u8` byte and values prefixed by the `hash: [32]u8`. For null node entries, the level byte is the entire key, and for non-leaf `level > 0` node entries, the hash is the entire value. The key `[1]u8{ 0xFF }` is reserved as a metadata entry for storing the database version, database variant, and height of the tree. This gives the tree a maximum height of 254. In practice, with the default fanout degree of 32, the tree will rarely be taller than 5 (millions of entries) or 6 (billions of entries) levels.

This approach is different than e.g. Dolt's Prolly Tree implementation, which is a from-scratch b-tree that reads and writes its own pages and is used as the foundation of a full-blown relational database. okra is designed to be used as a simple syncable key/value store, and leverages LMDB to simplify the implementation to just the logical rebalancing operations and inhert all its ACID transaction properties.

Another point worth mentioning is that embracing a two-level approach (building the MST on top of a key/value store) changes the incentives around picking a fanout degree probability distribution function. Our naive `node.hash[31] < 256 / Q` condition produces a geometric distribution of degrees (asymmetrically more smaller values than larger values). This is bad for Dolt's implementation because they pack their own pages and thus want as consistenly-sized chunks as possible, so weight their rolling hash function to produce a PDF symmetric around the expected value. But here, the boundaries between the children of different nodes are just conceptual, and the underlying pages in the LMDB database can end up spanning several conceptual nodes, or vice versa. To be clear, this doesn't mean okra is more performant in any specific way, just that it enjoys a clean separation of concerns by building on LMDB.

okra has no external concept of versioning or time-travel. LMDB is copy-on-write, and open transactions retain a consistent view of a snapshot of the database, but the old blocks are garbage-collected once the last reference is closed. When we talk later about "comparing two merkle roots", we mean two separate database instances (e.g. on different machines), not two local revisions of the same database.

## External interface

okra comes in four flavors.

## Use cases

okra is good for things like storing CRDT operations or serving as a general persistence layer for decentralized pubsub messages.

## Choosing a branching factor

## References 

- https://hal.inria.fr/hal-02303490/document
- https://0fps.net/2020/12/19/peer-to-peer-ordered-search-indexes/
- https://www.dolthub.com/blog/2020-04-01-how-dolt-stores-table-data/
- https://www.dolthub.com/blog/2022-06-27-prolly-chunker/
- https://github.com/attic-labs/noms/blob/master/doc/intro.md#prolly-trees-probabilistic-b-trees
