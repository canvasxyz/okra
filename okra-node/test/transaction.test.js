import os from "node:os";
import fs from "node:fs";
import path from "node:path";

import test from "ava";

import { nanoid } from "nanoid";

import * as okra from "../index.js";
import { openTree } from "./utils.js";

test("Open and abort a read-only transaction", async (t) => {
  const directory = path.resolve(os.tmpdir(), nanoid());
  try {
    const tree = new okra.Tree(directory);
    const transaction = new okra.Transaction(tree, true);
    transaction.abort();
    tree.close();
    t.pass();
  } finally {
    fs.rmSync(directory, { recursive: true });
  }
});

test("Open and abort a read-write transaction", async (t) => {
  const directory = path.resolve(os.tmpdir(), nanoid());
  try {
    const tree = new okra.Tree(directory);
    const transaction = new okra.Transaction(tree, false);
    transaction.abort();
    tree.close();
    t.pass();
  } finally {
    fs.rmSync(directory, { recursive: true });
  }
});

test("Open and commit a read-write transaction", async (t) => {
  await openTree(async (tree) => {
    const root = await tree.write((txn) => {
      txn.set(Buffer.from("a"), Buffer.from("foo"));
      txn.set(Buffer.from("b"), Buffer.from("bar"));
      txn.set(Buffer.from("c"), Buffer.from("baz"));

      return txn.getRoot();
    });

    t.deepEqual(root, {
      level: 1,
      key: null,
      hash: Buffer.from("6246b94074d09feb644be1a1c12c1f50", "hex"),
    });
  });
});

test("Call .set in a read-only transaction", async (t) => {
  await openTree(async (tree) => {
    await t.throwsAsync(() =>
      tree.read((txn) => {
        txn.set(Buffer.from("a"), Buffer.from("foo"));
      }), { message: "ACCES" });
  });
});

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

test("Open a transaction with an invalid readOnly value", async (t) => {
  await openTree((tree) => {
    t.throws(() => {
      const transaction = new okra.Transaction(tree, 1);
    }, { message: "expected a boolean" });
  });
});

test("Basic sets and deletes", async (t) => {
  await openTree(async (tree) => {
    await tree.write((txn) => {
      txn.set(Buffer.from("a"), Buffer.from("foo"));
      txn.set(Buffer.from("b"), Buffer.from("bar"));
    });

    await tree.read((txn) => {
      t.deepEqual(txn.get(Buffer.from("a")), Buffer.from("foo"));
      t.deepEqual(txn.get(Buffer.from("b")), Buffer.from("bar"));
      t.deepEqual(txn.get(Buffer.from("c")), null);
    });

    await tree.write((txn) => {
      txn.delete(Buffer.from("b"));
    });

    await tree.read((txn) => {
      t.deepEqual(txn.get(Buffer.from("a")), Buffer.from("foo"));
      t.deepEqual(txn.get(Buffer.from("b")), null);
      t.deepEqual(txn.get(Buffer.from("c")), null);
    });
  });
});

test("Get internal merkle tree nodes", async (t) => {
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

  await openTree(async (tree) => {
    await tree.write((txn) => {
      txn.set(a.key, a.value);
      txn.set(b.key, b.value);
      txn.set(c.key, c.value);
    });

    await tree.read((txn) => {
      t.deepEqual(txn.getNode(0, null), anchor);
      t.deepEqual(txn.getNode(0, a.key), a);
      t.deepEqual(txn.getNode(0, b.key), b);
      t.deepEqual(txn.getNode(0, c.key), c);
      t.deepEqual(txn.getChildren(1, null), [anchor, a, b, c]);
    });
  });
});

test("Seek to needle", async (t) => {
  const a = {
    level: 0,
    key: Buffer.from("a"),
    hash: Buffer.from("a0568b6bb51648ab5b2df66ca897ffa4", "hex"),
    value: Buffer.from([0]),
  };

  const c = {
    level: 0,
    key: Buffer.from("c"),
    hash: Buffer.from("690b688439b13abeb843a1d7a24d0ea7", "hex"),
    value: Buffer.from([2]),
  };

  await openTree(async (tree) => {
    await tree.write((txn) => {
      txn.set(a.key, a.value);
      txn.set(c.key, c.value);
    });

    await tree.read((txn) => {
      t.deepEqual(txn.seek(0, Buffer.from("b")), c);
      t.deepEqual(txn.seek(0, Buffer.from("d")), null);
      t.deepEqual(txn.seek(1, Buffer.from("a")), null);
    });
  });
});

test("Named databases", async (t) => {
  await openTree(async (tree) => {
    const key = Buffer.from("x");
    await tree.write((txn) => {
      txn.set(key, Buffer.from("foo"));
    }, { dbi: "a" });

    await tree.write((txn) => {
      txn.set(key, Buffer.from("bar"));
    }, { dbi: "b" });

    t.deepEqual(
      await tree.read((txn) => txn.get(key), { dbi: "a" }),
      Buffer.from("foo"),
    );

    t.deepEqual(
      await tree.read((txn) => txn.get(key), { dbi: "b" }),
      Buffer.from("bar"),
    );

    t.deepEqual(
      await tree.read((txn) => txn.get(key), { dbi: "c" }),
      null,
    );
  }, { dbs: ["a", "b", "c"] });
});

// test(
//   "get and set within named databases",
//   tmpdir((t, directory) => {
//     const tree = new okra.Tree(directory, {
//       dbs: ["a", "b"],
//     });

//     {
//       const txn = new okra.Transaction(tree, false, { dbi: "a" });
//       txn.set(Buffer.from("x"), Buffer.from("foo"));
//       txn.commit();
//     }

//     {
//       const txn = new okra.Transaction(tree, false, { dbi: "b" });
//       txn.set(Buffer.from("x"), Buffer.from("bar"));
//       txn.commit();
//     }

//     {
//       const txn = new okra.Transaction(tree, true, { dbi: "a" });
//       t.deepEqual(txn.get(Buffer.from("x")), Buffer.from("foo"));
//       txn.abort();
//     }

//     {
//       const txn = new okra.Transaction(tree, true, { dbi: "b" });
//       t.deepEqual(txn.get(Buffer.from("x")), Buffer.from("bar"));
//       txn.abort();
//     }

//     tree.close();
//     t.pass();
//   }),
// );

// test(
//   "try to open an invalid database name",
//   tmpdir((t, directory) => {
//     const tree = new okra.Tree(directory, {
//       dbs: ["a", "b"],
//     });

//     t.throws(() => {
//       new okra.Transaction(tree, false, { dbi: "c" });
//     }, { message: "DatabaseNotFound" });
//   }),
// );

// test(
//   "try to open the default database in a named environment",
//   tmpdir((t, directory) => {
//     const tree = new okra.Tree(directory, {
//       dbs: ["a", "b"],
//     });

//     t.throws(() => {
//       new okra.Transaction(tree, false);
//     }, { message: "InvalidDatabase" });
//   }),
// );
