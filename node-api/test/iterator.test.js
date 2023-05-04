import test from "ava"

import { openTree, node, encode } from "./utils.js"

test("Iterate over range", async (t) => {
	const entries = { a: "foo", b: "bar", c: "baz" }

	// L0 -----------------------------
	// af1349b9f5f9a1a6a0404dea36dcc949
	// 2f26b85f65eb9f7a8ac11e79e710148d "a"
	// 684f1047a178e6cf9fff759ba1edec2d "b"
	// 56cb13c78823525b08d471b6c1201360 "c"
	// L1 -----------------------------
	// 6246b94074d09feb644be1a1c12c1f50

	const levels = [
		[
			// L0
			node(0, null, "af1349b9f5f9a1a6a0404dea36dcc949"),
			node(0, "a", "2f26b85f65eb9f7a8ac11e79e710148d", "foo"),
			node(0, "b", "684f1047a178e6cf9fff759ba1edec2d", "bar"),
			node(0, "c", "56cb13c78823525b08d471b6c1201360", "baz"),
		],
		[
			// L1
			node(1, null, "6246b94074d09feb644be1a1c12c1f50"),
		],
	]

	await openTree(async (tree) => {
		await tree.write((txn) => {
			for (const [key, value] of Object.entries(entries)) {
				txn.set(encode(key), encode(value))
			}
		})

		await tree.read(async (txn) => {
			t.deepEqual(await collect(txn.nodes(0)), levels[0])
			t.deepEqual(await collect(txn.nodes(1)), levels[1])
			t.deepEqual(await collect(txn.nodes(2)), [])

			t.deepEqual(
				await collect(txn.nodes(0, { key: null, inclusive: true }, null)),
				levels[0]
			)
			t.deepEqual(
				await collect(txn.nodes(0, { key: null, inclusive: false }, null)),
				levels[0].slice(1)
			)
			t.deepEqual(
				await collect(
					txn.nodes(
						0,
						{ key: encode("a"), inclusive: false },
						{ key: encode("c"), inclusive: false }
					)
				),
				levels[0].slice(2, 3)
			)
			t.deepEqual(
				await collect(
					txn.nodes(
						0,
						{ key: encode("a"), inclusive: false },
						{ key: encode("c"), inclusive: false },
						{ reverse: true }
					)
				),
				levels[0].slice(2, 3).reverse()
			)
			t.deepEqual(
				await collect(
					txn.nodes(0, { key: null, inclusive: false }, null, { reverse: true })
				),
				levels[0].slice(1).reverse()
			)
		})
	})
})

async function collect(iter) {
	const values = []
	for await (const value of iter) {
		values.push(value)
	}

	return values
}
