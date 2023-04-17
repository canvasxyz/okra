import { blake3 } from "@noble/hashes/blake3"
import { Node } from "./schema.js"

export const K = 16
export const Q = 32

export const leafAnchorHash = blake3(new Uint8Array([]), { dkLen: K })

const limit = Number((1n << 32n) / BigInt(Q))

export function isSplit(hash: Uint8Array): boolean {
	const view = new DataView(hash.buffer, hash.byteOffset, 4)
	return view.getUint32(0) < limit
}

export function lessThan(a: Uint8Array | null, b: Uint8Array | null): boolean {
	if (a === null || b === null) {
		return b !== null
	}

	let x = a.length
	let y = b.length

	for (let i = 0, len = Math.min(x, y); i < len; ++i) {
		if (a[i] !== b[i]) {
			x = a[i]
			y = b[i]
			break
		}
	}

	return x < y
}

export const equalArrays = (a: Uint8Array, b: Uint8Array) =>
	a.length === b.length && a.every((byte, i) => byte === b[i])

export function equalKeys(a: Uint8Array | null, b: Uint8Array | null): boolean {
	if (a === null || b === null) {
		return a === null && b === null
	} else {
		return equalArrays(a, b)
	}
}

export const equalNodes = <T>(a: Node, b: Node) =>
	a.level === b.level && equalKeys(a.key, b.key) && equalArrays(a.hash, b.hash)

const size = new ArrayBuffer(4)
const view = new DataView(size)

export function hashEntry(key: Uint8Array, value: Uint8Array): Uint8Array {
	const hash = blake3.create({ dkLen: K })
	view.setUint32(0, key.length)
	hash.update(new Uint8Array(size))
	hash.update(key)
	view.setUint32(0, value.length)
	hash.update(new Uint8Array(size))
	hash.update(value)
	return hash.digest()
}

const byteToHex = new Array<string>(0xff)

for (let n = 0; n <= 0xff; ++n) {
	byteToHex[n] = n.toString(16).padStart(2, "0")
}

export function toHex(value: Uint8Array) {
	const octects = new Array<string>(value.length)
	for (let i = 0; i < value.length; i++) {
		octects[i] = byteToHex[value[i]]
	}

	return octects.join("")
}

export function fromHex(value: string): Uint8Array {
	if (value.length % 2 !== 0) {
		throw new Error("invalid hex string")
	}

	const array = new Uint8Array(value.length / 2)
	for (let i = 0; i < value.length; i += 2) {
		array[i / 2] = parseInt(value.slice(i, i + 2), 16)
	}

	return array
}

export function shuffle<T>(array: T[]) {
	for (let i = array.length - 1; i > 0; i--) {
		const j = Math.floor(Math.random() * (i + 1))
		const temp = array[i]
		array[i] = array[j]
		array[j] = temp
	}
}
