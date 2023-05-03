import os from "node:os"
import fs from "node:fs"
import path from "node:path"

import { nanoid } from "nanoid"

import * as okra from "../index.js"

export function tmpdir(f) {
	return (t) => {
		const directory = path.resolve(os.tmpdir(), nanoid())
		fs.mkdirSync(directory)

		try {
			f(t, directory)
		} finally {
			fs.rmSync(directory, { recursive: true })
		}
	}
}

export async function openTree(callback, { dbs } = {}) {
	const directory = path.resolve(os.tmpdir(), nanoid())
	const tree = new okra.Tree(directory, { dbs })
	try {
		await callback(tree)
	} finally {
		await tree.close()
		fs.rmSync(directory, { recursive: true })
	}
}

const encoder = new TextEncoder()
export const encode = (text) => encoder.encode(text)

export const fromHex = (hex) => new Uint8Array(Buffer.from(hex, "hex"))

export const node = (level, key, hash, value) =>
	value === undefined
		? { level, key: key && encode(key), hash: fromHex(hash) }
		: {
				level,
				key: key && encode(key),
				hash: fromHex(hash),
				value: encode(value),
		  }
