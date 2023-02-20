import test from "ava";
import "fake-indexeddb/auto";

import { Tree } from "../lib/index.js";
import { fromHex } from "../lib/utils.js";

import { getEntries } from "./utils.js";

test("{ id }", async (t) => {
  const tree = await Tree.open("objects", { getID: ({ id }) => id });
  await tree.reset();

  const entries = getEntries(10);
  for (const [i, [key, value]] of entries.entries()) {
    await tree.set(key, { id: value, index: i });
  }

  const root = await tree.getRoot();
  t.deepEqual(root, {
    level: 1,
    key: null,
    hash: fromHex("ce07217404553b582a24717d11c861fe"),
  });

  for (const [i, [key, value]] of entries.entries()) {
    const object = await tree.get(key);
    t.deepEqual(object, { id: value, index: i });
  }
});
