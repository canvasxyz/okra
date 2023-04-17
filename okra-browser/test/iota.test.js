import test from "ava";
import "fake-indexeddb/auto";

import { locks } from "web-locks";
globalThis.navigator = { locks };

import { Tree } from "../lib/index.js";

import { fromHex } from "../lib/utils.js";

import { getEntries, minute, open } from "./utils.js";

test("iota 0", async (t) => {
  const db = await open("i0", ["store"]);
  const tree = await Tree.open(db, "store");
  const root = await tree.read((txn) => txn.getRoot());
  t.deepEqual(root, {
    level: 0,
    key: null,
    hash: fromHex("af1349b9f5f9a1a6a0404dea36dcc949"),
  });
});

test("iota 1", async (t) => {
  const db = await open("i1", ["store"]);
  const tree = await Tree.open(db, "store");

  const root = await tree.write(async (txn) => {
    await txn.reset();
    for (const [key, value] of getEntries(1)) {
      await txn.set(key, value);
    }

    return await txn.getRoot();
  });

  t.deepEqual(root, {
    level: 1,
    key: null,
    hash: fromHex("d57e1de8ca79df1307ff68c76766b991"),
  });
});

test("iota 10", async (t) => {
  const db = await open("i10", ["store"]);
  const tree = await Tree.open(db, "store");

  const root = await tree.write(async (txn) => {
    await txn.reset();
    for (const [key, value] of getEntries(10)) {
      await txn.set(key, value);
    }

    return await txn.getRoot();
  });

  t.deepEqual(root, {
    level: 1,
    key: null,
    hash: fromHex("ce07217404553b582a24717d11c861fe"),
  });
});

test("iota 100", async (t) => {
  const db = await open("i100", ["store"]);
  const tree = await Tree.open(db, "store");

  const root = await tree.write(async (txn) => {
    await txn.reset();
    for (const [key, value] of getEntries(100)) {
      await txn.set(key, value);
    }

    return await txn.getRoot();
  });

  t.deepEqual(root, {
    level: 3,
    key: null,
    hash: fromHex("8efd6f7622e2bd0e52acc713056eb330"),
  });
});

test("iota 1000", async (t) => {
  t.timeout(1 * minute);

  const db = await open("i1000", ["store"]);
  const tree = await Tree.open(db, "store");

  const root = await tree.write(async (txn) => {
    await txn.reset();
    for (const [key, value] of getEntries(1000)) {
      await txn.set(key, value);
    }

    return await txn.getRoot();
  });

  t.deepEqual(root, {
    level: 2,
    key: null,
    hash: fromHex("d2c129466864bde37dcfa47488fe111f"),
  });
});
