import { IDBPCursorWithValue } from "idb"

export type Key = Uint8Array | null
export type Index = [number] | [number, Uint8Array | ArrayBuffer]

export function isIndex(index: unknown): index is Index {
	if (!Array.isArray(index)) {
		return false
	} else if (index.length === 0) {
		return false
	} else if (index.length > 2) {
		return false
	}

	const [level, key] = index
	if (typeof level !== "number") {
		return false
	} else if (level < 0) {
		return false
	} else if (!Number.isSafeInteger(level)) {
		return false
	}

	return (
		key === undefined || key instanceof Uint8Array || key instanceof ArrayBuffer
	)
}

export type Node = {
	level: number
	key: Key
	hash: Uint8Array
	value?: Uint8Array
}

export const toIndex = (level: number, key: Key): Index =>
	key ? [level, key] : [level]

export const getNode = (
	cursor:
		| IDBPCursorWithValue<unknown, [string], string, unknown, "readonly">
		| IDBPCursorWithValue<unknown, [string], string, unknown, "readwrite">
) => {
	if (!isIndex(cursor.key)) {
		throw new Error("invalid database")
	} else {
		const [level, key] = cursor.key
		return {
			level,
			key: key instanceof ArrayBuffer ? new Uint8Array(key) : key ?? null,
			...cursor.value,
		}
	}
}
