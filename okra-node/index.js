import { createRequire } from "node:module";
import { resolve } from "path";

import { familySync } from "detect-libc";

import { locks } from "web-locks";

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
    const absolutePath = resolve(path);
    super(absolutePath, options);
    this.path = absolutePath;
    this.controller = new AbortController();
  }

  async read(callback, { dbi } = {}) {
    const txn = new okra.Transaction(this, true, dbi ?? null);
    let result = undefined;
    try {
      result = await callback(txn);
    } finally {
      txn.abort();
    }

    return result;
  }

  async write(callback, { dbi } = {}) {
    // const writeController = new AbortController();
    // const abort = () => writeController.abort();
    // this.controller.signal.addEventListener("abort", abort);

    let result = undefined;
    try {
      await locks.request(
        `okra:${this.path}`,
        // { mode: "exclusive", signal: writeController.signal },
        { mode: "exclusive" },
        async (lock) => {
          if (lock === null) {
            throw new Error("unable to acquire exclusive lock");
          }

          const txn = new okra.Transaction(this, false, dbi ?? null);

          try {
            result = await callback(txn);
          } catch (err) {
            txn.abort();
            throw err;
          }

          txn.commit();
        },
      );
    } finally {
      // this.controller.signal.removeEventListener("abort", abort);
    }

    return result;
  }
}
