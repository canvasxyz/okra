import path from "node:path";

import test from "ava";

import * as okra from "../index.js";

import { tmpdir } from "./utils.js";

test(
  "Open and close a tree",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(path.resolve(directory, "data.okra"));
    tree.close();
    t.pass();
  }),
);

test(
  "Open tree without a path argument",
  tmpdir((t, directory) => {
    t.throws(() => {
      const tree = new okra.Tree();
    }, { message: "expected 1 arguments, received 0" });
  }),
);

test(
  "Open tree with an invalid path type",
  tmpdir((t, directory) => {
    t.throws(() => {
      const tree = new okra.Tree(8);
    }, { message: "string expected" });
  }),
);