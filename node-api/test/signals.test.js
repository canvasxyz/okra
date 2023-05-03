import test from "ava"

import { AbortError } from "p-queue"

import { openTree } from "./utils.js"

const wait = (t) => new Promise((resolve) => setTimeout(resolve, t))

test("abort queued write transactions", async (t) => {
	t.timeout(10000)
	await openTree(async (tree) => {
		await Promise.all([
			t.throwsAsync(
				tree.write(async (txn) => {
					await wait(500)
					tree.close()
				}),
				{ instanceOf: AbortError }
			),
			t.throwsAsync(
				tree.write(async (txn) => {
					console.log("starting txn 2")
				}),
				{ instanceOf: AbortError }
			),
		])
	})

	t.pass()
})
