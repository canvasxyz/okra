import { openDB, IDBPDatabase, IDBPObjectStore, IDBPTransaction } from "idb"

import { ReadOnlyTransaction, ReadWriteTransaction } from "./transaction.js"
import { defaultObjectStoreName, getIDRaw, leafAnchorHash } from "./utils.js"
import { Node, Key } from "./schema.js"

export type Options<T> = {
  dbs?: string[]
  getID?: (value: T) => Uint8Array
  initializeStore?: (dbi: string, store: IDBPObjectStore<unknown, string[], string, "versionchange">) => void
  upgrade?: (db: IDBPDatabase, oldVersion: number, newVersion: number | null, transaction: IDBPTransaction<unknown, string[], "versionchange">) => void
}

export class Tree<T = Uint8Array> {
  public static async open<T = Uint8Array>(name: string, options: Options<T> = {}): Promise<Tree<T>> {
    const dbs = options.dbs ?? [defaultObjectStoreName]
    const db = await openDB(name, 1, {
      upgrade(db, oldVersion, newVersion, transaction) {
        for (const dbi of dbs) {
          const store = db.createObjectStore(dbi)
          store.put({ hash: leafAnchorHash }, [0])
          if (options.initializeStore) {
            options.initializeStore(dbi, store)
          }
        }

        if (options.upgrade) {
          options.upgrade(db, oldVersion, newVersion, transaction)
        }
      }
    })

    return new Tree(db, dbs, options.getID ?? getIDRaw)
  }

  private constructor(
    public readonly db: IDBPDatabase,
    public readonly dbs: string[],
    public readonly getID: (value: T) => Uint8Array,
  ) { }

  public async read<R = void>(callback: (txn: ReadOnlyTransaction<T>) => Promise<R> | R, options: { dbi?: string } = {}): Promise<R> {
    const dbi = options.dbi ?? defaultObjectStoreName
    if (!this.dbs.includes(dbi)) {
      throw new Error("invalid dbi name")
    }

    const txn = await ReadOnlyTransaction.open<T>(this.db, dbi, this.getID)
    let result: R
    try {
      result = await callback(txn)
    } finally {
      txn.close()
    }
    return result
  }

  public async write<R = void>(callback: (txn: ReadWriteTransaction<T>) => Promise<R> | R, options: { dbi?: string } = {}): Promise<R> {
    const dbi = options.dbi ?? defaultObjectStoreName
    if (!this.dbs.includes(dbi)) {
      throw new Error("invalid dbi name")
    }

    const txn = await ReadWriteTransaction.open<T>(this.db, dbi, this.getID)
    let result: R
    try {
      result = await callback(txn)
    } finally {
      txn.close()
    }

    return result
  }

  public close() {
    this.db.close()
  }

  public async reset(): Promise<void> {
    await Promise.all(this.dbs.map((dbi) => this.write((txn) => txn.reset(), { dbi })))
  }
}
