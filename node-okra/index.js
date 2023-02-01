import { createRequire } from "node:module";

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
    super(path, options);
  }
}

export class Transaction extends okra.Transaction {
  constructor(tree, options) {
    super(tree, options);
  }
}

export class Cursor extends okra.Cursor {
  constructor(txn) {
    super(txn);
  }
}
