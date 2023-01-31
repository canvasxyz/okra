import { createRequire } from "node:module";

import { familySync } from "detect-libc";

const family = familySync();

const { platform, arch } = process;

const target = family === null
  ? `${arch}-${platform}`
  : `${arch}-${platform}-${family}`;

const require = createRequire(import.meta.url);

const { Tree, Transaction, Cursor } = require(`./build/${target}/okra.node`);

export { Cursor, Transaction, Tree };
