import path from "node:path";

import test from "ava";

import * as okra from "../index.js";

import { tmpdir } from "./utils.js";

test(
  "Open cursor",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(path.resolve(directory, "data.okra"));

    {
      const txn = new okra.Transaction(tree, { readOnly: false });
      txn.set(Buffer.from("a"), Buffer.from("foo"));
      txn.set(Buffer.from("b"), Buffer.from("baz"));
      txn.set(Buffer.from("c"), Buffer.from("bar"));
      txn.commit();
    }

    {
      const txn = new okra.Transaction(tree, { readOnly: true });
      const cursor = new okra.Cursor(txn);
      const root = cursor.goToRoot();
      t.deepEqual(root, {
        level: 1,
        key: null,
        hash: Buffer.from("34c52f171a19da9c861ec3f469c675d6", "hex"),
      });

      cursor.close();
      txn.abort();
    }

    tree.close();
  }),
);
