# @canvas-js/okra-browser

Pure JS/IndexedDB okra implementation.

## Table of Contents

- [Installation](#installation)
- [API](#api)
  - [Tree](#tree)
  - [Transactions](#transactions)

## Installation

```
npm i @canvas-js/okra-browser
```

```js
import * as okra from "@canvas-js/okra-browser"

const tree = await okra.Tree.open("example")

const toHex = (hash) => ([...hash]).map((byte) => byte.toString(16).padStart(2, "0")).join("")

// all reads and writes take place within transaction callbacks
await tree.read(async (txn) => {
  const root = await txn.getRoot();
  console.log(root) // Object { level: 0, key: null, hash: Uint8Array(16) }
  console.log(toHex(root.hash)) // af1349b9f5f9a1a6a0404dea36dcc949
}) 

const encoder = new TextEncoder()
await tree.write(async (txn) => {
  await txn.set(encoder.encode("a"), encoder.encode("foo"))
  await txn.set(encoder.encode("b"), encoder.encode("bar"))
  await txn.set(encoder.encode("c"), encoder.encode("baz"))

  const root = await txn.getRoot();
  console.log(root) // Object { level: 1, key: null, hash: Uint8Array(16) }
  console.log(toHex(root.hash)) // 6246b94074d09feb644be1a1c12c1f50
})
```

## API

The basic interfaces are `Tree`, `ReadOnlyTransaction`, and `ReadWriteTransaction`. Trees and transactions form a classical key/value store interface: you can open a tree, use the `tree.read((txn) => { ... })` and `tree.write((txn) => { ... })` callbacks to open managed transactions, and use the transaction to get, set, and delete key/value entries. **Don't create or close transactions directly.**

Transactions also have `getRoot`, `getNode`, and `getChildren` methods to access the internal merkle tree. These methods return `Node` objects. `node.key === null` for anchor nodes, and `node.value === undefined` if `level > 0 || key === null`.

```ts
class Tree<T = Uint8Array> {
  public static open<T = Uint8Array>(
    name: string,
    options?: { dbs?: string[]; getID?: (value: T) => Uint8Array },
  ): Promise<Tree<T>>;

  // Open a read-only transaction. Acquires a shared lock that is released when the callback resolves.
  public read<R = void>(
    callback: (txn: ReadOnlyTransaction<T>) => Promise<R> | R,
    options?: { dbi?: string },
  ): Promise<R>;

  // Open a read-write transaction. Acquire an exclusive lock that is released when the callback resolves.
  public write<R = void>(
    callback: (txn: ReadWriteTransaction<T>) => Promise<R> | R,
    options?: { dbi?: string },
  ): Promise<R>;

  public close(): void;
}
```

### Transactions

```ts
type Node<T = Uint8Array> = {
  level: number;
  key: Key;
  hash: Uint8Array;
  value?: T;
};
```

```ts
interface ReadOnlyTransaction<T> {
  // get a leaf key/value entry
  public get(key: Uint8Array): Promise<T | null>

  // get internal merkle tree nodes
  public getRoot(): Promise<Node<T>>
  public getNode(level: number, key: Key): Promise<Node>
  public getChildren(level: number, key: Key): Promise<Node<T>[]>
  public seek(level: number, key: Key): Promise<Node<T> | null>
}

interface ReadWriteTransaction<T> extends ReadOnlyTransaction<T> {
  // set a leaf key/value entry
  public set(key: Uint8Array, value: T): Promise<void>

  // delete a leaf key/value entry
  public delete(key: Uint8Array): Promise<void>
}
```
