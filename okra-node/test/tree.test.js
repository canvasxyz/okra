import os from "node:os";
import fs from "node:fs";
import path from "node:path";

import test from "ava";
import { nanoid } from "nanoid";

import * as okra from "../index.js";

test("Open and close a tree", (t) => {
  const directory = path.resolve(os.tmpdir(), nanoid());

  try {
    const tree = new okra.Tree(directory);
    tree.close();
    t.pass();
  } finally {
    fs.rmSync(directory, { recursive: true });
  }
});

test("Open tree without a path argument", (t) => {
  t.throws(() => {
    const tree = new okra.Tree();
  });
});

test("Open tree with an invalid path type", (t) => {
  t.throws(() => {
    const tree = new okra.Tree(8);
  });
});

test("Open tree an array of database names", (t) => {
  const directory = path.resolve(os.tmpdir(), nanoid());
  try {
    const tree = new okra.Tree(directory, { dbs: ["a", "b"] });
    tree.close();
    t.pass();
  } finally {
    fs.rmSync(directory, { recursive: true });
  }
});
