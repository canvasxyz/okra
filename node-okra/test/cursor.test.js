import test from "ava";

import * as okra from "../index.js";

import { tmpdir } from "./utils.js";

test(
  "Open cursor",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory);

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

test(
  "goToNode(), goToNext(), goToPrevious()",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory);

    const anchor = {
      level: 0,
      key: null,
      hash: Buffer.from("af1349b9f5f9a1a6a0404dea36dcc949", "hex"),
    };

    const a = {
      level: 0,
      key: Buffer.from("a"),
      hash: Buffer.from("a0568b6bb51648ab5b2df66ca897ffa4", "hex"),
      value: Buffer.from([0]),
    };

    const b = {
      level: 0,
      key: Buffer.from("b"),
      hash: Buffer.from("d21fa5d709077fd5594f180a8825852a", "hex"),
      value: Buffer.from([1]),
    };

    const c = {
      level: 0,
      key: Buffer.from("c"),
      hash: Buffer.from("690b688439b13abeb843a1d7a24d0ea7", "hex"),
      value: Buffer.from([2]),
    };

    {
      const txn = new okra.Transaction(tree, { readOnly: false });
      txn.set(a.key, a.value);
      txn.set(b.key, b.value);
      txn.set(c.key, c.value);
      txn.commit();
    }

    {
      const txn = new okra.Transaction(tree, { readOnly: true });
      const cursor = new okra.Cursor(txn);
      t.deepEqual(cursor.goToNode(0, null), anchor);
      t.deepEqual(cursor.goToNext(), a);
      t.deepEqual(cursor.goToNext(), b);
      t.deepEqual(cursor.goToNext(), c);
      t.deepEqual(cursor.goToNext(), null);
      t.deepEqual(cursor.goToNode(0, a.key), a);
      t.deepEqual(cursor.goToPrevious(), anchor);
      t.deepEqual(cursor.goToPrevious(), null);

      cursor.close();
      txn.abort();
    }

    tree.close();
  }),
);
