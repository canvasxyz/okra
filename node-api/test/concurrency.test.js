import test from "ava"
import { openTree } from "./utils.js"

const encoder = new TextEncoder()
const encode = (value) => encoder.encode(value)
const fromHex = (hex) => new Uint8Array(Buffer.from(hex, "hex"))

const wait = (t) => new Promise((resolve) => setTimeout(resolve, t))

test("open a write txn during an open read txn", async (t) => {
	await openTree(async (tree) => {
		await tree.read(async (readTxn1) => {
			await wait(100)

			const root = await tree.write(async (writeTxn) => {
				await wait(100)
				writeTxn.set(encode("a"), encode("foo"))
				writeTxn.set(encode("b"), encode("bar"))
				writeTxn.set(encode("c"), encode("baz"))
				return writeTxn.getRoot()
			})

			t.deepEqual(root, {
				level: 1,
				key: null,
				hash: fromHex("6246b94074d09feb644be1a1c12c1f50"),
			})

			t.deepEqual(readTxn1.getRoot(), {
				level: 0,
				key: null,
				hash: fromHex("af1349b9f5f9a1a6a0404dea36dcc949"),
			})

			t.deepEqual(await tree.read((txn) => txn.getRoot()), root)
		})
	})
})

test("open concurrent writes", async (t) => {
	await openTree(async (tree) => {
		let index = 0
		const order = await Promise.all([
			tree.write(async (txn) => {
				await wait(500)
				return index++
			}),
			tree.write(async (txn) => {
				await wait(500)
				return index++
			}),
		])

		t.deepEqual(order, [0, 1])
	})
})

test("open lots of concurrent writes", async (t) => {
	await openTree(async (tree) => {
		let index = 0
		const order = await Promise.all([
			tree.write(async (txn) => {
				await wait(100)
				return index++
			}),
			tree.write(async (txn) => {
				await wait(100)
				return index++
			}),
			tree.write(async (txn) => {
				await wait(100)
				return index++
			}),
			tree.write(async (txn) => {
				await wait(100)
				return index++
			}),
			tree.write(async (txn) => {
				await wait(100)
				return index++
			}),
		])

		t.deepEqual(order, [0, 1, 2, 3, 4])
	})
})
