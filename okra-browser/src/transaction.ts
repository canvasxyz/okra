import { IDBPDatabase, IDBPTransaction } from 'idb'
import { blake3 } from '@noble/hashes/blake3'
import debug from "debug"

import { toIndex, Key, Node, getNode, isIndex } from "./schema.js"
import { equalKeys, getIDRaw, hashEntry, isSplit, K, leafAnchorHash, lessThan } from './utils.js'

// we have enums at home
const Result = { Update: 0, Delete: 1 } as const
type Result = typeof Result[keyof typeof Result]

type Operation<T> = { type: "set", key: Uint8Array, value: T } | { type: "delete", key: Uint8Array }

class BaseTransaction<T> {
  public open = true
  constructor(
    public readonly db: IDBPDatabase,
    public readonly dbi: string,
    public readonly getID: (value: T) => Uint8Array,
  ) { }

  public async getRoot(options: {
    txn?: IDBPTransaction<unknown, [string], "readwrite"> | IDBPTransaction<unknown, [string], "readonly">
  } = {}): Promise<Node<T>> {
    if (!this.open) {
      throw new Error("transaction closed")
    }

    const txn = options.txn ?? this.db.transaction(this.dbi, "readonly")
    const cursor = await txn.store.openCursor(null, "prev")
    if (cursor === null || !isIndex(cursor.key)) {
      throw new Error("invalid database")
    }

    const [level, key] = cursor.key
    if (key !== undefined) {
      throw new Error("invalid database")
    }

    const { hash, value } = cursor.value
    if (value !== undefined) {
      throw new Error("invalid database")
    }

    return { level, key: null, hash }
  }

  public async getNode(level: number, key: Key, options: {
    txn?: IDBPTransaction<unknown, [string], "readwrite"> | IDBPTransaction<unknown, [string], "readonly">
  } = {}): Promise<Node<T>> {
    if (!this.open) {
      throw new Error("transaction closed")
    }

    const txn = options.txn ?? this.db.transaction(this.dbi, "readonly")
    const node = await txn.store.get(toIndex(level, key))
    if (node === undefined) {
      throw new Error("key not found")
    }

    return { level, key, ...node }
  }

  public async get(key: Uint8Array, options: {
    txn?: IDBPTransaction<unknown, [string], "readwrite"> | IDBPTransaction<unknown, [string], "readonly">
  } = {}): Promise<T | null> {
    if (!this.open) {
      throw new Error("transaction closed")
    }

    const txn = options.txn ?? this.db.transaction(this.dbi, "readonly")
    const node = await txn.store.get([0, key])
    if (node === undefined) {
      return null
    } else if (node.value === undefined) {
      throw new Error("invalid database")
    } else {
      return node.value
    }
  }

  public async seek(level: number, key: Key, options: {
    txn?: IDBPTransaction<unknown, [string], "readwrite"> | IDBPTransaction<unknown, [string], "readonly">
  } = {}): Promise<Node<T> | null> {
    if (!this.open) {
      throw new Error("transaction closed")
    }

    const txn = options.txn ?? this.db.transaction(this.dbi, "readonly")
    const range = IDBKeyRange.lowerBound(toIndex(level, key))
    let cursor = await txn.store.openCursor(range, "next")
    if (cursor === null) {
      return null
    }

    const node = getNode<T>(cursor)
    return node.level === level ? node : null
  }

  public async getChildren(level: number, key: Key, options: {
    txn?: IDBPTransaction<unknown, [string], "readwrite"> | IDBPTransaction<unknown, [string], "readonly">
  } = {}): Promise<Node<T>[]> {
    if (!this.open) {
      throw new Error("transaction closed")
    }

    if (level === 0) {
      throw new Error('cannot get children of a leaf node')
    }

    const children: Node<T>[] = []
    for await (const node of this.range(level - 1, key, options)) {
      children.push(node)
    }

    return children
  }


  public async *range(level: number, firstChild: Key, options: {
    txn?: IDBPTransaction<unknown, [string], "readwrite"> | IDBPTransaction<unknown, [string], "readonly">
  } = {}): AsyncIterable<Node<T>> {
    if (!this.open) {
      throw new Error("transaction closed")
    }

    const txn = options.txn ?? this.db.transaction(this.dbi, "readonly")
    const range = IDBKeyRange.lowerBound(toIndex(level, firstChild))
    let cursor = await txn.store.openCursor(range, "next")
    if (cursor === null) {
      throw new Error("invalid database")
    }

    let node = getNode<T>(cursor)
    if (node.level !== level || !equalKeys(node.key, firstChild)) {
      console.error("looking for", level, firstChild, "and got", node)
      throw new Error("key not found")
    }

    yield node

    while (cursor = await cursor.continue()) {
      const node = getNode<T>(cursor)
      if (node.level !== level || isSplit(node.hash)) {
        break
      } else {
        yield node
      }
    }
  }
}

export class ReadOnlyTransaction<T = Uint8Array> extends BaseTransaction<T> {
  public static open<T = Uint8Array>(db: IDBPDatabase, dbi: string, getID: (value: T) => Uint8Array = getIDRaw) {
    const name = `okra:${db.name}:${dbi}`
    const log = debug(`${name}:read`)
    return new Promise<ReadOnlyTransaction<T>>((resolve, reject) => {
      log("requesting shared lock")
      navigator.locks.request(name, { mode: "shared" }, (lock) => {
        if (lock === null) {
          reject(new Error(`failed to acquire shared lock ${name}`))
        } else {
          log("acquired shared lock")
          return new Promise<void>((release) => {
            resolve(new ReadOnlyTransaction<T>(db, dbi, getID, lock, release, log))
          })
        }
      })
    })
  }

  private constructor(
    db: IDBPDatabase,
    dbi: string,
    getID: (value: T) => Uint8Array,
    private readonly lock: Lock,
    private readonly release: () => void,
    private readonly log: debug.Debugger,
  ) {
    super(db, dbi, getID)
  }

  public close() {
    this.log("releasing shared lock")
    this.open = false
    this.release()
  }
}

export class ReadWriteTransaction<T = Uint8Array> extends BaseTransaction<T> {
  public static open<T = Uint8Array>(db: IDBPDatabase, dbi: string, getID: (value: T) => Uint8Array = getIDRaw) {
    const name = `okra:${db.name}:${dbi}`
    const log = debug(`${name}:write`)
    return new Promise<ReadWriteTransaction<T>>((resolve, reject) => {
      log("requesting exclusive lock")
      navigator.locks.request(name, { mode: "exclusive" }, (lock) => {
        if (lock === null) {
          reject(new Error(`failed to acquire exclusive lock ${name}`))
        } else {
          log("acquired exclusive lock")
          return new Promise<void>((release) => {
            resolve(new ReadWriteTransaction<T>(db, dbi, getID, lock, release, log))
          })
        }
      })
    })
  }

  private constructor(
    db: IDBPDatabase,
    dbi: string,
    getID: (value: T) => Uint8Array,
    private readonly lock: Lock,
    private readonly release: () => void,
    private readonly log: debug.Debugger,
  ) {
    super(db, dbi, getID)
  }

  public close() {
    this.log("releasing exclusive lock")
    this.open = false
    this.release()
  }

  public async reset() {
    if (!this.open) {
      throw new Error("transaction closed")
    }

    await this.db.clear(this.dbi)
    await this.db.put(this.dbi, { hash: leafAnchorHash }, [0])
  }

  private newSiblings: Key[] = []

  public async set(key: Uint8Array, value: T): Promise<void> {
    if (!this.open) {
      throw new Error("transaction closed")
    }

    const txn = this.db.transaction(this.dbi, "readwrite")
    try {
      await this.apply(txn, { type: "set", key, value })
    } catch (err) {
      txn.abort()
      throw err
    }

    txn.commit()
  }

  public async delete(key: Uint8Array): Promise<void> {
    if (!this.open) {
      throw new Error("transaction closed")
    }


    const txn = this.db.transaction(this.dbi, "readwrite")
    try {
      await this.apply(txn, { type: "delete", key })
    } catch (err) {
      txn.abort()
      throw err
    }

    txn.commit()
  }

  private async apply(txn: IDBPTransaction<unknown, [string], "readwrite">, operation: Operation<T>): Promise<void> {
    if (this.newSiblings.length !== 0) {
      throw new Error("internal error")
    }

    const root = await this.getRoot({ txn })

    const result = root.level === 0
      ? await this.applyLeaf(txn, null, operation)
      : await this.applyNode(txn, root.level - 1, null, operation)

    if (result === Result.Delete) {
      throw new Error("internal error")
    }

    let rootLevel = root.level || 1

    await this.hashNode(txn, rootLevel, null)

    while (this.newSiblings.length > 0) {
      await this.promote(txn, rootLevel)
      rootLevel += 1
      await this.hashNode(txn, rootLevel, null)
    }

    while (rootLevel > 0) {
      const { key: last } = await this.getLast(txn, rootLevel - 1)
      if (last !== null) {
        break
      } else {
        await txn.store.delete(toIndex(rootLevel, null))
      }

      rootLevel--
    }
  }

  private async applyLeaf(
    txn: IDBPTransaction<unknown, [string], "readwrite">,
    firstChild: Key,
    operation: Operation<T>,
  ): Promise<Result> {
    if (operation.type === "set") {
      const leaf: Node<T> = {
        level: 0,
        key: operation.key,
        hash: hashEntry(operation.key, this.getID(operation.value)),
        value: operation.value,
      }

      await this.setNode(txn, leaf)
      if (lessThan(firstChild, operation.key)) {
        if (isSplit(leaf.hash)) {
          this.newSiblings.push(operation.key)
        }

        return Result.Update
      } else if (equalKeys(firstChild, operation.key)) {
        if (firstChild === null || isSplit(leaf.hash)) {
          return Result.Update
        } else {
          return Result.Delete
        }
      } else {
        throw new Error("invalid database")
      }
    } else if (operation.type === "delete") {
      await txn.store.delete(toIndex(0, operation.key))
      if (equalKeys(operation.key, firstChild)) {
        return Result.Delete
      } else {
        return Result.Update
      }
    } else {
      throw new Error("invalid operation type")
    }
  }

  private async applyNode(
    txn: IDBPTransaction<unknown, [string], "readwrite">,
    level: number,
    firstChild: Key,
    operation: Operation<T>,
  ): Promise<Result> {
    if (level === 0) {
      return this.applyLeaf(txn, firstChild, operation)
    }

    const target = await this.findTarget(txn, level, firstChild, operation.key)

    const isLeftEdge = firstChild === null
    const isFirstChild = equalKeys(target, firstChild)

    const result = await this.applyNode(txn, level - 1, target, operation)
    if (result === Result.Delete) {
      if (isLeftEdge && isFirstChild) {
        throw new Error("internal error")
      }

      const previousChild = await this.moveToPreviousChild(txn, level, target)


      await this.promote(txn, level)

      const isPreviousChildSplit = await this.hashNode(txn, level, previousChild)

      if (isFirstChild || lessThan(previousChild, firstChild)) {
        if (isPreviousChildSplit) {
          this.newSiblings.push(previousChild)
        }

        return Result.Delete
      } else if (equalKeys(previousChild, firstChild)) {
        if (isLeftEdge || isPreviousChildSplit) {
          return Result.Update
        } else {
          return Result.Delete
        }
      } else {
        if (isPreviousChildSplit) {
          this.newSiblings.push(previousChild)
        }

        return Result.Update
      }
    } else {
      const isTargetSplit = await this.hashNode(txn, level, target)

      await this.promote(txn, level)

      if (isFirstChild) {
        if (isTargetSplit || isLeftEdge) {
          return Result.Update
        } else {
          return Result.Delete
        }
      } else {
        if (isTargetSplit) {
          this.newSiblings.push(target)
        }

        return Result.Update
      }
    }
  }

  private async promote(
    txn: IDBPTransaction<unknown, [string], "readwrite">,
    level: number,
  ): Promise<void> {
    const newSiblings: Key[] = []
    for (const newChild of this.newSiblings) {
      const isSplit = await this.hashNode(txn, level, newChild)
      if (isSplit) {
        newSiblings.push(newChild)
      }
    }

    this.newSiblings = newSiblings
  }

  private async findTarget(
    txn: IDBPTransaction<unknown, [string], "readwrite">,
    level: number,
    firstChild: Key,
    key: Uint8Array,
  ): Promise<Key> {
    let target: Node<T> | undefined = undefined
    for await (const node of this.range(level, firstChild, { txn })) {
      if (lessThan(key, node.key)) {
        break
      } else {
        target = node
      }
    }

    if (target === undefined) {
      throw new Error("invalid database")
    } else {
      return target.key
    }
  }

  // deletes the target key and moves backwards until it finds a new one.
  // this method is responsible for some magic so be really careful.
  private async moveToPreviousChild(
    txn: IDBPTransaction<unknown, [string], "readwrite">,
    level: number,
    target: Key,
  ): Promise<Key> {
    if (level === 0) {
      throw new Error("internal error")
    }

    const index = toIndex(level, target)
    await txn.store.delete(index)
    const range = IDBKeyRange.upperBound(index, true)
    let cursor = await txn.store.openCursor(range, "prev")
    while (cursor !== null) {

      const { key: previousChild } = getNode(cursor)
      if (previousChild === null) {
        return null
      }

      const previousGrandChild = await this.getNode(level - 1, previousChild, { txn })
      if (isSplit(previousGrandChild.hash)) {
        return previousChild
      }

      await txn.store.delete(toIndex(level, previousChild))
      cursor = await cursor.continue()
    }

    throw new Error("internal error")
  }


  // Computes and sets the hash of the given node.
  // Doesn't assume anything about the current cursor position.
  // Returns isSplit for the updated hash.
  private async hashNode(
    txn: IDBPTransaction<unknown, [string], "readwrite">,
    level: number,
    key: Key,
  ): Promise<boolean> {
    const hash = blake3.create({ dkLen: K })
    for await (const node of this.range(level - 1, key, { txn })) {
      hash.update(node.hash)
    }

    const node: Node<T> = { level, key, hash: hash.digest() }
    await this.setNode(txn, node)
    return isSplit(node.hash)
  }

  private async setNode(
    txn: IDBPTransaction<unknown, [string], "readwrite">,
    { level, key, ...node }: Node<T>,
  ): Promise<void> {
    await txn.store.put(node, toIndex(level, key))
  }

  private async getLast(
    txn: IDBPTransaction<unknown, [string], "readwrite">,
    level: number,
  ): Promise<Node<T>> {
    const range = IDBKeyRange.upperBound(toIndex(level + 1, null), true)
    const cursor = await txn.store.openCursor(range, "prev")
    if (cursor === null) {
      throw new Error("invalid database")
    } else {
      return getNode(cursor)
    }
  }
}
