```
          oooo
          `888
 .ooooo.   888  oooo  oooo d8b  .oooo.
d88' `88b  888 .8P'   `888""8P `P  )88b
888   888  888888.     888      .oP"888
888   888  888 `88b.   888     d8(  888
`Y8bod8P' o888o o888o d888b    `Y888""8o
```

Okra is a Prolly Tree written in Zig and built on top of LMDB.

You can use Okra as a persistent key/value store. Internally, it has a special merkle tree structure that **enables a new class of efficient p2p syncing algorithms**. For example, if you have a peer-to-peer network in which peers publish CRDT operations but occasionally go offline and miss operations, two peers can use okra to quickly identify missing operations without relying on version vectors.

## Table of Contents

- [Usage](#Usage)
- [Design](#design)
- [Benchmarks](#benchmarks)
- [References](#references)
- [Contributing](#contributing)
- [License](#license)

## Usage

The internal Zig structs are documented in [API.md](API.md) and the NodeJS bindings are documented in [node-api/README.md](./node-api/).

## Design

okra is a Prolly Tree whose leaves are key/value entries sorted lexicographically by key. It has three crucial properties:

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

Okra has no external concept of versioning or time-travel. LMDB is copy-on-write, and open transactions retain a consistent view of a snapshot of the database, but the old pages are garbage-collected once the last transaction referencing them is closed. When we talk about "comparing two merkle roots", we mean two separate database instances (e.g. on different machines), not two local revisions of the same database.

## Tests

Run all tests with `zig build test`.

Okra is currently built with zig version `0.11.0-dev.3947+89396ff02`.

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
