import type { Buffer } from "node:buffer"

declare class Tree {
	constructor(path: string)
	insert(leaf: Buffer, hash: Buffer): void
	close(): void
}

declare class Scanner {
	constructor(tree: Tree)
	seek(level: number, leaf: null | Buffer): { leaf: Buffer; hash: Buffer }[]
	close(): void
}
