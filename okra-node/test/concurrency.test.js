import os from "node:os";
import fs from "node:fs";
import path from "node:path";

import test from "ava";
import { nanoid } from "nanoid";
import * as okra from "../index.js";

const encoder = new TextEncoder();
const encode = (value) => encoder.encode(value);
const fromHex = (hex) => new Uint8Array(Buffer.from(hex, "hex"));

const wait = (t) => new Promise((resolve) => setTimeout(resolve, t));

test("open a write txn during an open read txn", async (t) => {
  const directory = path.resolve(os.tmpdir(), nanoid());
  try {
    const tree = new okra.Tree(directory);
    const readTxn1 = new okra.Transaction(tree, true);
    await wait(100);
    const writeTxn = new okra.Transaction(tree, false);
    await wait(100);
    writeTxn.set(encode("a"), encode("foo"));
    writeTxn.set(encode("b"), encode("bar"));
    writeTxn.set(encode("c"), encode("baz"));
    t.deepEqual(writeTxn.getRoot(), {
      level: 1,
      key: null,
      hash: fromHex("6246b94074d09feb644be1a1c12c1f50"),
    });

    writeTxn.commit();

    await wait(100);

    t.deepEqual(readTxn1.getRoot(), {
      level: 0,
      key: null,
      hash: fromHex("af1349b9f5f9a1a6a0404dea36dcc949"),
    });

    const readTxn2 = new okra.Transaction(tree, true);
    t.deepEqual(readTxn2.getRoot(), {
      level: 1,
      key: null,
      hash: fromHex("6246b94074d09feb644be1a1c12c1f50"),
    });

    readTxn1.abort();
    readTxn2.abort();

    tree.close();
    t.pass();
  } finally {
    fs.rmSync(directory, { recursive: true });
  }
});
