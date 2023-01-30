import type { Buffer } from "node:buffer"

declare class Tree {
	constructor(path: string)
	close(): void
}

declare class Transaction {
	constructor(tree: Tree, options: { readOnly: boolean })
	abort(): void
	commit(): void

	get(key: Buffer): Buffer | null
	set(key: Buffer, value: Buffer): void
	delete(key: Buffer): void
}

declare type Node = {
	level: Number
	key: Buffer | null
	hash: Buffer
	value?: Buffer
}

declare class Cursor {
	constructor(txn: Transaction)
	goToRoot(): Node
	goToNode(level: number, key: Buffer | null): Node
	goToNext(): Node | null
	goToPrevious(): Node | null
	seek(level: number, key: Buffer | null): Node | null
	close(): void
}
