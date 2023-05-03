# @canvas-js/okra-node

[![NPM version](https://img.shields.io/npm/v/@canvas-js/okra-node)](https://www.npmjs.com/package/@canvas-js/okra-node) ![TypeScript types](https://img.shields.io/npm/types/@canvas-js/okra-node)

Native NodeJS bindings for Okra over LMDB.

## Table of Contents

- [Installation](#installation)
- [Usage](#usage)
- [API](#api)
  - [Tree](#tree)
  - [Transaction](#transaction)

## Installation

```
npm i @canvas-js/okra-node
```

## Usage

```ts
import * as okra from "@canvas-js/okra-node"

const encoder = new TextEncoder()
const e = (text) => encoder.encode(text)

// the Tree constructor will create a directory at /path/to/db
// if one does not already exist
const tree = new okra.Tree("/path/to/db")
const txn = new okra.ReadWriteTransaction(tree)
txn.set(e("a"), e("foo"))
txn.commit()

// alternatively, you can use the .read and .write methods,
// which manage commits and aborts automatically.
await tree.write(async (txn) => {
  // the callback here can await on other async operations,
  // but the transaction calls themselves are still synchronous.
  txn.set(e("b"), e("bar"))
  txn.set(e("c"), e("baz"))
})

await tree.read(async (txn) => {
  console.log(txn.get(e("a"))) // Uint8Array(3) [ 102, 111, 111 ] ("foo")
  console.log(txn.get(e("b"))) // Uint8Array(3) [ 99, 97, 114 ]   ("bar")
  console.log(txn.get(e("c"))) // null

  console.log(txn.getRoot())
  // {
  //   level: 1,
  //   key: null,
  //   hash: Uint8Array(16) [
  //     98,  70, 185,  64, 116,
  //     208, 159, 235, 100,  75,
  //     225, 161, 193,  44,  31,
  //     80
  //   ]
  // }
})

tree.close()
```

## API

The two basic classes are `Tree` and `Transaction`. Trees and transactions form a classical key/value store interface: you can open a tree, use the tree to open read-only or read-write transactions, and use the transaction to get, set, and delete key/value entries.

Transactions also have `getRoot`, `getNode`, and `getChildren` methods and an async `nodes` iterator to access the internal merkle tree. These methods return `Node` objects. `node.key === null` for anchor nodes, and `node.value === undefined` if `level > 0 || key === null`.

```ts
type Key = Uint8Array | null

type Node = {
  level: number
  key: Key
  hash: Uint8Array
  value?: Uint8Array
}
```

### Tree

```ts
class Tree {
  constructor(path: string, options?: { mapSize?: number, dbs?: string[] })

  /**
   * Close the tree and free its associated resources
   */
  public close(): void

  /**
	 * Open a manageded read-only transaction
	 */
	public read<R>(callback: (txn: ReadOnlyTransaction) => Promise<R> | R): Promise<R>

	/**
	 * Open a manageded read-write transaction
	 */
	public write<R>(callback: (txn: ReadWriteTransaction) => Promise<R> | R): Promise<R>
}
```

The `path` must be a path to a directory.

LMDB has optional support for multiple [named databases](http://www.lmdb.tech/doc/group__mdb.html#gac08cad5b096925642ca359a6d6f0562a) (called "DBI handles") within a single LMDB environment. By default, okra trees interact with the single default LMDB DBI. You can opt in to using isolated named DBIs by setting `options.dbs: string[]` in the tree constructor, and selecting a specific DBI with `options.dbi: string` with every transaction. Note that **these two modes are exclusive**: if the tree has`options.dbs === undefined`, then every transaction's `options.dbi` must also be `undefined`, and if the tree has `options.dbs !== undefined` then every transaction's `options.dbi` must be one of the values in array.

### Transaction

The easiest way to open trasactions is using the managed `read` and `write` methods on the `Tree`. However, they can also be opened manually using the `ReadOnlyTransaction` and `ReadWriteTransaction` class constructors. If you manage transactions yourself, you must only try to open read-write transaction at a time. The `Tree` uses an internal `PQueue` with `{ concurrency: 1 }` to enforce this for transactions opened with `tree.write(...)`.

```ts
export type Bound = { key: Key; inclusive: boolean }

interface ReadOnlyTransaction {
  /**
   * Abort the transaction
   */
  abort(): void

  /**
   * Get the value of an entry
   * @param {Uint8Array} key
   * @returns the entry's value, or null if the entry does not exist
   */
  get(key: Uint8Array): Uint8Array | null

  /**
   * Get an internal skip-list node
   * @param level node level
   * @param key node key (null for anchor nodes)
   * @throws if the node does not exist
   */
  getNode(level: number, key: Key): Node

  /**
   * Get the root of the internal skip-list
   */
  getRoot(): Node

  /**
   * Get the children of an internal skip-list node
   * @param level node level (cannot be zero)
   * @param key node key (null for anchor nodes)
   * @throws if level == 0 or if the node does not exist
   */
  getChildren(level: number, key: Key): Node[]

  nodes(
    level: number,
    lowerBound?: Bound | null,
    upperBound?: Bound | null,
    options?: { reverse?: boolean }
  ): AsyncIterableIterator<Node>
}

interface ReadWriteTransaction extends ReadOnlyTransaction {
  /**
   * Commit the transaction
   */
  commit(): void

  /**
   * Set a key/value entry
   * @param {Uint8Array} key
   * @param {Uint8Array} value
   * @throws if the transaction is read-only
   */
  set(key: Uint8Array, value: Uint8Array): void

  /**
   * Delete an entry
   * @param {Uint8Array} key
   * @throws if the transaction is read-only or if the entry does not exist
   */
  delete(key: Uint8Array): void
}

export class ReadOnlyTransaction implements ReadOnlyTransaction {}

export class ReadWriteTransaction implements ReadWriteTransaction {}
```

## License

MIT © 2023 Canvas Technologies, Inc.
