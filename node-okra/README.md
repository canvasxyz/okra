# node-okra

NodeJS bindings for okra.

## Table of Contents

- [Installation](#installation)
- [API](#api)
  - [Tree](#tree)
  - [Transaction](#transaction)
  - [Cursor](#cursor)

## Installation

```
npm i node-okra
```

```ts
import * as okra from "node-okra"

const tree = new okra.Tree("/path/to/db.okra")
const txn = new okra.Transaction(tree, { readOnly: false })
txn.set(Buffer.from("foo"), Buffer.from("bar"))
txn.commit()
// ...
```

## API

The three basic classes are `Tree`, `Transaction`, and `Cursor`. Trees and transactions form a classical key/value store interface: you can open a tree, use the tree to open read-only or read-write transactions, and use the transaction to get, set, and delete key/value entries. A cursor can be used to move around the nodes of the tree itself, which includes the leaves, the intermediate-level nodes, and the root node.

Cursor methods and some transaction methods return `Node` objects. `node.key === null` for anchor nodes, and `node.value === undefined` if `level > 0 || key === null`.

```ts
declare type Node = {
	level: number
	key: Buffer | null
	hash: Buffer
	value?: Buffer
}
```

### Tree

```ts
declare namespace Tree {
	type Options = { mapSize?: number, dbs?: string[] }
}

declare class Tree {
  constructor(path: string, options: Tree.Options = {})

  /**
   * Close the tree and free its associated resources
   */
  close(): void
}
```

The `path` must be a an absolute path to a **directory** that already exists (LMDB will not make it for you).

LMDB has optional support for multiple [named databases](http://www.lmdb.tech/doc/group__mdb.html#gac08cad5b096925642ca359a6d6f0562a) (called "DBI handles") within a single LMDB environment. By default, okra trees interact with the single default LMDB DBI. You can opt in to using isolated named DBIs by setting `Tree.Options.dbs: string[]` in the tree constructor, and selecting a specific DBI with `Transaction.Options.dbi: string` with every transaction. Note that **these two modes are exclusive**: if `Tree.Options.dbs === undefined`, then every `Transaction.Options.dbi` must also be `undefined`, and if `Tree.Options.dbs !== undefined` then every `Transaction.Options.dbi` must be one of the values in `Tree.Options.dbs`.

### Transaction

```ts
declare namespace Transaction {
	type Options = { readOnly: boolean; dbi?: string }
}

declare class Transaction {
  /**
   * Transactions must be opened as either read-only or read-write.
   * Only one read-write transaction can be open at a time.
   * Read-only transactions must be manually aborted when finished,
   * and read-write transactions must be either aborted or committed.
   * Failure to abort or commmit transactions will cause the database
   * file to grow.
   */
  constructor(tree: Tree, options: Transaction.Options)

  /**
   * Abort the transaction
   */
  abort(): void

  /**
   * Commit the transaction
   * @throws if the transaction is read-only
   */
  commit(): void

  /**
   * Get the value of an entry
   * @param {Buffer} key
   * @returns the entry's value, or null if the entry does not exist
   */
  get(key: Buffer): Buffer | null

  /**
   * Set a key/value entry
   * @param {Buffer} key
   * @param {Buffer} value
   * @throws if the transaction is read-only
   */
  set(key: Buffer, value: Buffer): void

  /**
   * Delete an entry
   * @param {Buffer} key
   * @throws if the transaction is read-only or if the entry does not exist
   */
  delete(key: Buffer): void

  /**
   * Get an internal skip-list node
   * @param level node level
   * @param key node key (null for anchor nodes)
   * @throws if the node does not exist
   */
  getNode(level: number, key: Buffer | null): Node

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
  getChildren(level: number, key: Buffer | null): Node[]
}
```

### Cursor

```ts
declare class Cursor {
  /**
   * Cursors can be opened using read-write or read-only transactions,
   * and must be closed before the transaction is aborted or committed.
   */
  constructor(txn: Transaction)

  /**
   * Close the cursor and free its associated resources
   */
  close(): void

  /**
   * Go to the root node
   */
  goToRoot(): Node

  /**
   * Go to an internal skip-list node
   * @param level node level
   * @param key node key (null for anchor nodes)
   */
  goToNode(level: number, key: Buffer | null): Node

  /**
   * Go to the next sibling on the same level.
   * goToNext() and goToPrevious() ignore parent boundaries: they can be used to traverse an entire level from beginning to end.
   */
  goToNext(): Node | null

  /**
   * Go to the previous sibling on the same level.
   * goToNext() and goToPrevious() ignore parent boundaries: they can be used to traverse an entire level from beginning to end.
   */
  goToPrevious(): Node | null

  /**
   * Seek to the first node on the given level with a key greater than or equal to the provided search key
   * @param level
   * @param key
   */
  seek(level: number, key: Buffer | null): Node | null
}
```