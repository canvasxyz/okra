import test from "ava";

import { AbortError } from "p-queue";

import { openTree } from "./utils.js";

const encoder = new TextEncoder();
const encode = (value) => encoder.encode(value);
const fromHex = (hex) => new Uint8Array(Buffer.from(hex, "hex"));

const wait = (t) => new Promise((resolve) => setTimeout(resolve, t));

const result = (p) =>
  p
    .then((value) => ({ status: "success", value }))
    .catch((err) => ({ status: "failure", error: err }));

test("abort queued write transactions", async (t) => {
  t.timeout(10000);
  await openTree(async (tree) => {
    await Promise.all([
      t.throwsAsync(
        tree.write(async (txn) => {
          await wait(500);
          tree.close();
        }),
        { instanceOf: AbortError },
      ),
      t.throwsAsync(
        tree.write(async (txn) => {
          console.log("starting txn 2");
        }),
        { instanceOf: AbortError },
      ),
    ]);
  });

  t.pass();
});
