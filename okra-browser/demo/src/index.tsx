import { createRoot } from "react-dom/client"

import { sha256 } from "@noble/hashes/sha256"

import { Tree } from "../../lib/index.js"
import { toHex } from "../../lib/utils.js"

import { shuffle } from "./utils.js"
import { useCallback, useState } from "react"

const tree = await Tree.open("example")
await tree.reset()
await tree.read(async (txn) => {
  const root = await txn.getRoot()
  console.log(([...root.hash]).map((byte) => byte.toString(16).padStart(2, "0")).join(""))
})

const encoder = new TextEncoder()
await tree.write(async (txn) => {
  await txn.set(encoder.encode("a"), encoder.encode("foo"))
  await txn.set(encoder.encode("b"), encoder.encode("bar"))
  await txn.set(encoder.encode("c"), encoder.encode("baz"))

  const root = await txn.getRoot()
  console.log(root)
  console.log(toHex(root.hash)) // 
})

function getEntries(iota: number) {
  const entries = []
  for (let i = 0; i < iota; i++) {
    const buffer = new ArrayBuffer(2)
    new DataView(buffer, 0, 2).setUint16(0, i)
    const key = new Uint8Array(buffer)
    entries.push([key, sha256(key)])
  }

  shuffle(entries)
  return entries
}

const Index: React.FC<{}> = ({ }) => {
  const [isWaiting, setIsWaiting] = useState(false)
  const [isRunning, setIsRunning] = useState(false)
  const [root, setRoot] = useState<null | string>(null)

  const exec = useCallback(async ({ }) => {
    setIsWaiting(true)
    console.log("nice")

    const iota = 1000
    const entries = getEntries(iota)

    const start = window.performance.now()

    await tree.write(async (txn) => {
      setRoot(null)
      setIsWaiting(false)
      setIsRunning(true)
      await txn.reset()
      for (const [key, value] of entries) {
        await txn.set(key, value)
      }

      const rootNode = await txn.getRoot()
      setRoot(toHex(rootNode.hash))
    })

    setIsRunning(false)
    const end = window.performance.now()
    console.log(`done in ${end - start}ms`)
  }, [])

  return <div>
    <button onClick={exec}>execute</button>
    <pre><code>{isWaiting ? "requesting lock..." : isRunning ? "running..." : root}</code></pre>
  </div>
}

const main = document.querySelector("main")
const root = createRoot(main!)
root.render(<Index />)

