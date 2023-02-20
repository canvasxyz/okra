import test from "ava";
import "fake-indexeddb/auto";

import { ReadOnlyTransaction, Tree } from "../lib/index.js";
import { fromHex } from "../lib/utils.js";

test("[a, b]", async (t) => {
  const tree = await Tree.open("dbsAB", { dbs: ["a", "b"] });
  await tree.reset();

  {
    const txn = new ReadOnlyTransaction(tree.db, "a");
    const root = await txn.getRoot();

    t.deepEqual(root, {
      level: 0,
      key: null,
      hash: fromHex("af1349b9f5f9a1a6a0404dea36dcc949"),
    });
  }

  {
    const txn = new ReadOnlyTransaction(tree.db, "b");
    const root = await txn.getRoot();

    t.deepEqual(root, {
      level: 0,
      key: null,
      hash: fromHex("af1349b9f5f9a1a6a0404dea36dcc949"),
    });
  }
});
