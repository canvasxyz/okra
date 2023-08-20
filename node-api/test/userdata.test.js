import os from "node:os"
import fs from "node:fs"
import path from "node:path"

import test from "ava"
import { nanoid } from "nanoid"

import * as okra from "../index.js"

test("set and get userdata", async (t) => {
	const directory = path.resolve(os.tmpdir(), nanoid())

	const userdata = new TextEncoder().encode("ayo")

	try {
		const tree = new okra.Tree(directory)
		await tree.read((txn) => t.is(txn.getUserdata(), null))
		await tree.write((txn) => txn.setUserdata(userdata))
		await tree.read((txn) => t.deepEqual(txn.getUserdata(), userdata))

		tree.close()
		t.pass()
	} finally {
		fs.rmSync(directory, { recursive: true })
	}
})
