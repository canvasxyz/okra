import test from "ava";

import * as okra from "../index.js";

import { tmpdir } from "./utils.js";

test(
  "Open and abort a read-only transaction",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory);
    const transaction = new okra.Transaction(tree, true);
    transaction.abort();
    tree.close();
    t.pass();
  }),
);

test(
  "Open and abort a read-write transaction",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory);
    const transaction = new okra.Transaction(tree, false);
    transaction.abort();
    tree.close();
    t.pass();
  }),
);

test(
  "Open and commit a read-write transaction",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory);
    const transaction = new okra.Transaction(tree, false);
    transaction.commit();
    tree.close();
    t.pass();
  }),
);

test(
  "Call .set in a read-only transaction",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory);
    const transaction = new okra.Transaction(tree, true);
    t.throws(() => {
      transaction.set(Buffer.from("foo"), Buffer.from("bar"));
      transaction.commit();
    }, { message: "ACCES" });
    tree.close();
  }),
);

test(
  "Open a transaction with an invalid tree argument",
  (t) => {
    class Tree {}
    const tree = new Tree();
    t.throws(() => {
      const transaction = new okra.Transaction(tree, true);
    }, { message: "invalid object type tag" });
  },
);

test(
  "Open a transaction with an invalid readOnly value",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory);
    t.throws(() => {
      const transaction = new okra.Transaction(tree, 1);
    }, { message: "expected a boolean" });
    tree.close();
  }),
);

test(
  "Set, delete, commit, get",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory);

    {
      const txn = new okra.Transaction(tree, false);
      txn.set(Buffer.from("a"), Buffer.from("foo"));
      txn.set(Buffer.from("b"), Buffer.from("bar"));
      txn.commit();
    }

    {
      const txn = new okra.Transaction(tree, true);
      t.deepEqual(txn.get(Buffer.from("a")), Buffer.from("foo"));
      t.deepEqual(txn.get(Buffer.from("b")), Buffer.from("bar"));
      t.deepEqual(txn.get(Buffer.from("c")), null);
      txn.abort();
    }

    {
      const txn = new okra.Transaction(tree, false);
      txn.delete(Buffer.from("b"));
      txn.commit();
    }

    {
      const txn = new okra.Transaction(tree, true);
      t.deepEqual(txn.get(Buffer.from("a")), Buffer.from("foo"));
      t.deepEqual(txn.get(Buffer.from("b")), null);
      t.deepEqual(txn.get(Buffer.from("c")), null);
      txn.abort();
    }

    tree.close();
  }),
);

test(
  "getRoot, getNode, getChildren",
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
      const txn = new okra.Transaction(tree, false);

      t.deepEqual(txn.getRoot(), {
        level: 0,
        key: null,
        hash: Buffer.from("af1349b9f5f9a1a6a0404dea36dcc949", "hex"),
      });

      txn.set(a.key, a.value);
      txn.set(b.key, b.value);
      txn.set(c.key, c.value);
      txn.commit();
    }

    {
      const txn = new okra.Transaction(tree, true);
      t.deepEqual(txn.getNode(0, null), anchor);
      t.deepEqual(txn.getNode(0, a.key), a);
      t.deepEqual(txn.getNode(0, b.key), b);
      t.deepEqual(txn.getNode(0, c.key), c);
      t.deepEqual(txn.getChildren(1, null), [anchor, a, b, c]);
      txn.abort();
    }

    tree.close();
  }),
);

test(
  "get and set within named databases",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory, {
      dbs: ["a", "b"],
    });

    {
      const txn = new okra.Transaction(tree, false, { dbi: "a" });
      txn.set(Buffer.from("x"), Buffer.from("foo"));
      txn.commit();
    }

    {
      const txn = new okra.Transaction(tree, false, { dbi: "b" });
      txn.set(Buffer.from("x"), Buffer.from("bar"));
      txn.commit();
    }

    {
      const txn = new okra.Transaction(tree, true, { dbi: "a" });
      t.deepEqual(txn.get(Buffer.from("x")), Buffer.from("foo"));
      txn.abort();
    }

    {
      const txn = new okra.Transaction(tree, true, { dbi: "b" });
      t.deepEqual(txn.get(Buffer.from("x")), Buffer.from("bar"));
      txn.abort();
    }

    tree.close();
    t.pass();
  }),
);

test(
  "try to open an invalid database name",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory, {
      dbs: ["a", "b"],
    });

    t.throws(() => {
      new okra.Transaction(tree, false, { dbi: "c" });
    }, { message: "DatabaseNotFound" });
  }),
);

test(
  "try to open the default database in a named environment",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(directory, {
      dbs: ["a", "b"],
    });

    t.throws(() => {
      new okra.Transaction(tree, false);
    }, { message: "InvalidDatabase" });
  }),
);
