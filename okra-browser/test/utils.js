import { sha256 } from "@noble/hashes/sha256";

import { equalArrays, lessThan, shuffle } from "../lib/utils.js";

export const second = 1000;
export const minute = 60 * second;

export function getEntries(iota) {
  const entries = [];
  for (let i = 0; i < iota; i++) {
    const buffer = new ArrayBuffer(2);
    new DataView(buffer, 0, 2).setUint16(0, i);
    const key = new Uint8Array(buffer);
    entries.push([key, sha256(key)]);
  }

  shuffle(entries);
  return entries;
}

export function sortEntries([a], [b]) {
  if (lessThan(a, b)) {
    return -1;
  } else if (equalArrays(a, b)) {
    return 0;
  } else {
    return 1;
  }
}
