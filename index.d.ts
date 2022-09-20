import type { Buffer } from "node:buffer"

declare class Tree {
	constructor(path: string)
	insert(leaf: Buffer, hash: Buffer): void
	close(): void
}

declare class Source {
	constructor(tree: Tree)
	getRootLevel(): number
	get(level: number, leaf: null | Buffer): { leaf: Buffer; hash: Buffer }[]
	close(): void
}

declare class Target {
	constructor(tree: Tree)
	getRootLevel(): number
	filter(nodes: { leaf: Buffer; hash: Buffer }[]): Buffer[]
	close(): void
}
