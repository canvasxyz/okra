# @canvas-js/okra-node

Native NodeJS bindings for okra on LMDB.

## Table of Contents

- [Installation](#installation)
- [API](#api)
  - [Tree](#tree)
  - [Transaction](#transaction)

## Installation

```
npm i @canvas-js/okra-node
```

```ts
import * as okra from "@canvas-js/okra-node"

// the Tree constructor will create a directory at /path/to/db
// if one does not already exist
const tree = new okra.Tree("/path/to/db")
const txn = new okra.Transaction(tree, { readOnly: false })
txn.set(Buffer.from("a"), Buffer.from("foo"))
txn.commit()

// alternatively, you can use the .read and .write methods,
// which manage commits and aborts automatically.
await tree.write(async (txn) => {
  txn.set(Buffer.from("b"), Buffer.from("bar"))
})

await tree.read(async (txn) => {
  console.log(txn.get(Buffer.from("a"))) // <Buffer 66 6f 6f> ("foo")
  console.log(txn.get(Buffer.from("b"))) // <Buffer 62 61 72> ("bar")
  console.log(txn.get(Buffer.from("c"))) // null
})

tree.close()
```

## API

The two basic classes are `Tree` and `Transaction`. Trees and transactions form a classical key/value store interface: you can open a tree, use the tree to open read-only or read-write transactions, and use the transaction to get, set, and delete key/value entries.

Transactions also have `getRoot`, `getNode`, and `getChildren` methods to access the internal merkle tree. These methods return `Node` objects. `node.key === null` for anchor nodes, and `node.value === undefined` if `level > 0 || key === null`.

```ts
type Node = {
  level: number
  key: Buffer | null
  hash: Buffer
  value?: Buffer
}
```

### Tree

```ts
class Tree {
  constructor(path: string, options?: { mapSize?: number, dbs?: string[] })

  /**
   * Close the tree and free its associated resources
   */
  close(): void

  /**
	 * Open a manageded read-only transaction
	 */
	public read<R>(callback: (txn: Transaction) => Promise<R> | R): Promise<R>

	/**
	 * Open a manageded read-write transaction
	 */
	public write<R>(callback: (txn: Transaction) => Promise<R> | R): Promise<R>
}
```

The `path` must be a path to a directory.

LMDB has optional support for multiple [named databases](http://www.lmdb.tech/doc/group__mdb.html#gac08cad5b096925642ca359a6d6f0562a) (called "DBI handles") within a single LMDB environment. By default, okra trees interact with the single default LMDB DBI. You can opt in to using isolated named DBIs by setting `Tree.Options.dbs: string[]` in the tree constructor, and selecting a specific DBI with `Transaction.Options.dbi: string` with every transaction. Note that **these two modes are exclusive**: if `Tree.Options.dbs === undefined`, then every `Transaction.Options.dbi` must also be `undefined`, and if `Tree.Options.dbs !== undefined` then every `Transaction.Options.dbi` must be one of the values in `Tree.Options.dbs`.

### Transaction

```ts
class Transaction {
  /**
   * Transactions are opened as either read-only or read-write.
   * Only one read-write transaction can be open at a time.
   * Read-only transactions must be manually aborted when finished,
   * and read-write transactions must be either aborted or committed.
   * Failure to abort or commmit transactions will cause the database
   * file to grow.
   */
  constructor(tree: Tree, readOnly: boolean, options?: { dbi?: string })

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

  /**
   * Get the first node at a given level whose key is
   * greater than or equal to the provided needle.
   */
  seek(level: number, needle: Buffer | null): Node | null
}
```
