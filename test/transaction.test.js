import path from "node:path";

import test from "ava";

import * as okra from "../index.js";

import { tmpdir } from "./utils.js";

test(
  "Open and abort a read-only transaction",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(path.resolve(directory, "data.okra"));
    const transaction = new okra.Transaction(tree, { readOnly: true });
    transaction.abort();
    tree.close();
    t.pass();
  }),
);

test(
  "Open and abort a read-write transaction",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(path.resolve(directory, "data.okra"));
    const transaction = new okra.Transaction(tree, { readOnly: false });
    transaction.abort();
    tree.close();
    t.pass();
  }),
);

test(
  "Open and commit a read-write transaction",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(path.resolve(directory, "data.okra"));
    const transaction = new okra.Transaction(tree, { readOnly: false });
    transaction.commit();
    tree.close();
    t.pass();
  }),
);

test(
  "Call .set in a read-only transaction",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(path.resolve(directory, "data.okra"));
    const transaction = new okra.Transaction(tree, { readOnly: true });
    t.throws(() => {
      transaction.set(Buffer.from("foo"), Buffer.from("bar"));
      transaction.commit();
    }, { message: "LmdbTransactionError" });
    tree.close();
  }),
);

test(
  "Open a transaction with an invalid tree argument",
  (t) => {
    class Tree {}
    const tree = new Tree();
    t.throws(() => {
      const transaction = new okra.Transaction(tree, { readOnly: true });
    }, { message: "invalid object type tag" });
  },
);

test(
  "Open a transaction without the options argument",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(path.resolve(directory, "data.okra"));
    t.throws(() => {
      const transaction = new okra.Transaction(tree);
    }, { message: "expected 2 arguments, received 1" });
    tree.close();
  }),
);

test(
  "Open a transaction with an invalid readOnly value",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(path.resolve(directory, "data.okra"));
    t.throws(() => {
      const transaction = new okra.Transaction(tree, { readOnly: 1 });
    }, { message: "expected a boolean" });
    tree.close();
  }),
);

test(
  "Set, commit, get",
  tmpdir((t, directory) => {
    const tree = new okra.Tree(path.resolve(directory, "data.okra"));

    {
      const txn = new okra.Transaction(tree, { readOnly: false });
      txn.set(Buffer.from("a"), Buffer.from("foo"));
      txn.commit();
    }

    {
      const txn = new okra.Transaction(tree, { readOnly: true });
      t.deepEqual(txn.get(Buffer.from("a")), Buffer.from("foo"));
      txn.abort();
    }

    tree.close();
  }),
);
