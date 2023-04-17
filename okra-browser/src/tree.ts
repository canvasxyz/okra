import { IDBPDatabase } from "idb"

import debug from "debug"

import { ReadOnlyTransaction, ReadWriteTransaction } from "./transaction.js"
import { leafAnchorHash } from "./utils.js"

export class Tree {
	private readonly id: string

	public static async open(db: IDBPDatabase, storeName: string): Promise<Tree> {
		const tree = new Tree(db, storeName)
		await db.put(storeName, { hash: leafAnchorHash }, [0])
		return tree
	}

	private constructor(
		public readonly db: IDBPDatabase,
		public readonly storeName: string
	) {
		this.id = `okra:${this.db.name}:${this.storeName}`
	}

	public async read<R = void>(
		callback: (txn: ReadOnlyTransaction) => Promise<R> | R
	): Promise<R> {
		const log = debug(`${this.id}:read`)
		log("requesting shared lock")

		let result: R | undefined = undefined
		await navigator.locks.request(this.id, { mode: "shared" }, async (lock) => {
			if (lock === null) {
				throw new Error(`failed to acquire shared lock ${name}`)
			}

			log("acquired shared lock")
			const txn = new ReadOnlyTransaction(this.db, this.storeName)
			try {
				result = await callback(txn)
			} finally {
				txn.close()
				log("releasing shared lock")
			}
		})

		return result!
	}

	public async write<R = void>(
		callback: (txn: ReadWriteTransaction) => Promise<R> | R
	): Promise<R> {
		const log = debug(`${this.id}:write`)

		let result: R | undefined = undefined
		await navigator.locks.request(
			this.id,
			{ mode: "exclusive" },
			async (lock) => {
				if (lock === null) {
					throw new Error(`failed to acquire exclusive lock ${name}`)
				}

				log("acquired exclusive lock")
				const txn = new ReadWriteTransaction(this.db, this.storeName)
				try {
					result = await callback(txn)
				} finally {
					txn.close()
					log("releasing exclusive lock")
				}
			}
		)

		return result!
	}
}
