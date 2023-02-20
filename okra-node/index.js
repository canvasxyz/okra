import { createRequire } from "node:module";
import { resolve } from "path";

import { familySync } from "detect-libc";

const family = familySync();

const { platform, arch } = process;

const target = family === null
  ? `${arch}-${platform}`
  : `${arch}-${platform}-${family}`;

const require = createRequire(import.meta.url);

const okra = require(
  `./build/${target}/okra.node`,
);

export class Tree extends okra.Tree {
  constructor(path, options = {}) {
    super(resolve(path), options);
  }

  async read(callback, options = {}) {
    const txn = new Transaction(this, true, options);
    let result = undefined;
    try {
      result = await callback(txn);
    } finally {
      txn.abort();
    }

    return result;
  }

  async write(callback, options = {}) {
    const txn = new Transaction(this, false, options);
    let result = undefined;
    try {
      result = await callback(txn);
    } catch (err) {
      txn.abort();
      throw err;
    }

    txn.commit();
    return result;
  }
}

export class Transaction extends okra.Transaction {
  constructor(tree, readOnly, options = {}) {
    const dbi = options.dbi ?? null;
    super(tree, readOnly, dbi);
  }
}
