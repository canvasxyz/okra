import type { Buffer } from "node:buffer"

declare class Tree {
	constructor(path: string)

	/**
	 * Close the tree and free its associated resources
	 */
	close(): void
}

declare class Transaction {
	constructor(tree: Tree, options: { readOnly: boolean })

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

declare type Node = {
	level: number
	key: Buffer | null
	hash: Buffer
	value?: Buffer
}

declare class Cursor {
	constructor(txn: Transaction)

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

	/**
	 * Close the cursor and free its associated resources
	 */
	close(): void
}
