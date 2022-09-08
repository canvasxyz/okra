import { createRequire } from "node:module"

import { familySync } from "detect-libc"

const family = familySync()

const { platform, arch } = process

const target = family === null ? `${arch}-${platform}` : `${arch}-${platform}-${family}`

console.log("[okra] Detected target", target)

const require = createRequire(import.meta.url)

const { Tree, Scanner } = require(`./build/${target}/okra.node`)

export { Tree, Scanner }
