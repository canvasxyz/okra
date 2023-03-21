declare module "@canvas-js/okra-node" {
	export type Node = {
		level: number
		key: Uint8Array | null
		hash: Uint8Array
		value?: Uint8Array
	}

	export class Tree {
		constructor(path: string, options?: { mapSize?: number, dbs?: string[] })

		/**
		 * Close the tree and free its associated resources
		 */
		public close(): void

		/**
		 * Open a managed read-only transaction
		 */
		public read<R>(callback: (txn: ReadOnlyTransaction) => Promise<R> | R, options?: { dbi?: string }): Promise<R>

		/**
		 * Open a managed read-write transaction
		 */
		public write<R>(callback: (txn: ReadWriteTransaction) => Promise<R> | R, options?: { dbi?: string }): Promise<R>
	}

	export interface ReadOnlyTransaction {
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
		getNode(level: number, key: Uint8Array | null): Node

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
		getChildren(level: number, key: Uint8Array | null): Node[]

		/**
		 * Get the first node at a given level whose key is
		 * greater than or equal to the provided needle.
		 */
		seek(level: number, needle: Uint8Array | null): Node | null
	}

	export interface ReadWriteTransaction extends ReadOnlyTransaction {
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
}
