import test from "ava";

import { nanoid } from "nanoid";

import { openTree } from "./utils.js";

const encoder = new TextEncoder();
const encode = (value) => encoder.encode(value);
const fromHex = (hex) => new Uint8Array(Buffer.from(hex, "hex"));

test("Open and abort a read-only transaction", async (t) => {
  await openTree(async (tree) => {
    const message = nanoid();
    await t.throwsAsync(async () => {
      await tree.read(async (txn) => {
        throw new Error(message);
      });
    }, { message });
  });
});

test("Open and abort a read-write transaction", async (t) => {
  await openTree(async (tree) => {
    const message = nanoid();
    await t.throwsAsync(async () => {
      await tree.write(async (txn) => {
        throw new Error(message);
      });
    }, { message });
  });
});

test("Open and commit a read-write transaction", async (t) => {
  await openTree(async (tree) => {
    const root = await tree.write((txn) => {
      txn.set(encode("a"), encode("foo"));
      txn.set(encode("b"), encode("bar"));
      txn.set(encode("c"), encode("baz"));

      return txn.getRoot();
    });

    t.deepEqual(root, {
      level: 1,
      key: null,
      hash: fromHex("6246b94074d09feb644be1a1c12c1f50"),
    });
  });
});

test("Call .set in a read-only transaction", async (t) => {
  await openTree(async (tree) => {
    await t.throwsAsync(async () => {
      await tree.read((txn) => {
        txn.set(encode("a"), encode("foo"));
      });
    }, { message: "ACCES" });
  });
});

test("Basic sets and deletes", async (t) => {
  await openTree(async (tree) => {
    await tree.write((txn) => {
      txn.set(encode("a"), encode("foo"));
      txn.set(encode("b"), encode("bar"));
      txn.set(encode("c"), new Uint8Array([]));
    });

    await tree.read((txn) => {
      t.deepEqual(txn.get(encode("a")), encode("foo"));
      t.deepEqual(txn.get(encode("b")), encode("bar"));
      t.deepEqual(txn.get(encode("c")), new Uint8Array([]));
      t.deepEqual(txn.get(encode("d")), null);
    });

    await tree.write((txn) => {
      txn.delete(Buffer.from("b"));
    });

    await tree.read((txn) => {
      t.deepEqual(txn.get(encode("a")), encode("foo"));
      t.deepEqual(txn.get(encode("b")), null);
    });
  });
});

test("Get internal merkle tree nodes", async (t) => {
  const anchor = {
    level: 0,
    key: null,
    hash: fromHex("af1349b9f5f9a1a6a0404dea36dcc949"),
  };

  const a = {
    level: 0,
    key: encode("a"),
    hash: fromHex("a0568b6bb51648ab5b2df66ca897ffa4"),
    value: new Uint8Array([0]),
  };

  const b = {
    level: 0,
    key: encode("b"),
    hash: fromHex("d21fa5d709077fd5594f180a8825852a"),
    value: new Uint8Array([1]),
  };

  const c = {
    level: 0,
    key: encode("c"),
    hash: fromHex("690b688439b13abeb843a1d7a24d0ea7"),
    value: new Uint8Array([2]),
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
    key: encode("a"),
    hash: fromHex("a0568b6bb51648ab5b2df66ca897ffa4"),
    value: new Uint8Array([0]),
  };

  const c = {
    level: 0,
    key: encode("c"),
    hash: fromHex("690b688439b13abeb843a1d7a24d0ea7"),
    value: new Uint8Array([2]),
  };

  await openTree(async (tree) => {
    await tree.write((txn) => {
      txn.set(a.key, a.value);
      txn.set(c.key, c.value);
    });

    await tree.read((txn) => {
      t.deepEqual(txn.seek(0, encode("b")), c);
      t.deepEqual(txn.seek(0, encode("d")), null);
      t.deepEqual(txn.seek(1, encode("a")), null);
    });
  });
});

test("Named databases", async (t) => {
  await openTree(async (tree) => {
    const key = encode("x");
    await tree.write((txn) => {
      txn.set(key, encode("foo"));
    }, { dbi: "a" });

    await tree.write((txn) => {
      txn.set(key, encode("bar"));
    }, { dbi: "b" });

    t.deepEqual(
      await tree.read((txn) => txn.get(key), { dbi: "a" }),
      encode("foo"),
    );

    t.deepEqual(
      await tree.read((txn) => txn.get(key), { dbi: "b" }),
      encode("bar"),
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
