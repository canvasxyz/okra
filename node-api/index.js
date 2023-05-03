import { createRequire } from "node:module"
import { resolve } from "path"

import { familySync } from "detect-libc"

import PQueue from "p-queue"

const family = familySync()

const { platform, arch } = process

const target =
	family === null ? `${arch}-${platform}` : `${arch}-${platform}-${family}`

const require = createRequire(import.meta.url)

const okra = require(`./build/${target}/okra.node`)

export class Tree extends okra.Tree {
	constructor(path, options = {}) {
		super(resolve(path), options)
		this.controller = new AbortController()
		this.queue = new PQueue({ concurrency: 1 })
	}

	async read(callback, { dbi = null } = {}) {
		let result = undefined

		const txn = new ReadOnlyTransaction(this, { dbi })
		try {
			result = await callback(txn)
		} finally {
			txn.abort()
		}

		return result
	}

	async write(callback, { dbi } = {}) {
		let result = undefined

		await this.queue.add(
			async () => {
				const txn = new ReadWriteTransaction(this, { dbi })
				try {
					result = await callback(txn)
					txn.commit()
				} catch (err) {
					txn.abort()
					throw err
				}
			},
			{ signal: this.controller.signal }
		)

		return result
	}

	async close() {
		this.controller.abort()
		await this.queue.onIdle()
		super.close()
	}
}

export class ReadOnlyTransaction extends okra.Transaction {
	constructor(tree, { dbi = null } = {}) {
		super(tree, true, dbi)
	}

	async *nodes(level, lowerBound = null, upperBound = null, options = {}) {
		const reverse = options.reverse ?? false
		const iter = new okra.Iterator(this, level, lowerBound, upperBound, reverse)
		try {
			for (let node = iter.next(); node !== null; node = iter.next()) {
				yield node
			}
		} finally {
			iter.close()
		}
	}
}

export class ReadWriteTransaction extends okra.Transaction {
	constructor(tree, { dbi = null } = {}) {
		super(tree, false, dbi)
	}

	*nodes(level, lowerBound = null, upperBound = null, options = {}) {
		const reverse = options.reverse ?? false
		const iter = new okra.Iterator(this, level, lowerBound, upperBound, reverse)
		try {
			for (let node = iter.next(); node !== null; node = iter.next()) {
				yield node
			}
		} finally {
			iter.close()
		}
	}
}
