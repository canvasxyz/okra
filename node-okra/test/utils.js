import os from "node:os";
import fs from "node:fs";
import path from "node:path";

import { nanoid } from "nanoid";

export function tmpdir(f) {
  return (t) => {
    const directory = path.resolve(os.tmpdir(), nanoid());
    fs.mkdirSync(directory);

    try {
      f(t, directory);
    } finally {
      fs.rmSync(directory, { recursive: true });
    }
  };
}
