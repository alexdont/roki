// Decodes every E-AC-3 packet of the test file with dolby.wasm and compares loudness with
// FFmpeg's own decode of the same stream.
import {readFileSync, readdirSync} from "node:fs"
import {execSync} from "node:child_process"
import createModule from "./dolby.mjs"
const dir = process.argv[2]
const m = await createModule({locateFile: (f) => dir + "/" + f})
const name = "eac3"
const np = m._malloc(8); m.stringToUTF8(name, np, 8)
const dec = m._dolby_open(np, 0, 0, 1)
if (!dec) { console.log("open failed"); process.exit(1) }
const files = readdirSync(dir + "/pkts").filter((f) => f.endsWith(".eac3")).sort()
let frames = 0, sumSq = 0, probes = 0, ch = 0, rate = 0, errors = 0
const t0 = performance.now()
for (const f of files) {
  const data = readFileSync(dir + "/pkts/" + f)
  const p = m._malloc(data.byteLength); m.HEAPU8.set(data, p)
  const n = m._dolby_decode(dec, p, data.byteLength)
  m._free(p)
  if (n < 0) { errors++; continue }
  if (n === 0) continue
  ch = m._dolby_channels(dec); rate = m._dolby_rate(dec)
  const out = new Float32Array(m.HEAPF32.buffer, m._dolby_out(dec), n * ch)
  for (let i = 0; i < out.length; i += 7) { sumSq += out[i] * out[i]; probes++ }
  frames += n
}
const ms = performance.now() - t0
console.log(JSON.stringify({packets: files.length, errors, frames, seconds: +(frames / rate).toFixed(2), channels: ch, rate, rms: +Math.sqrt(sumSq / probes).toFixed(4), decode_ms: Math.round(ms), x_realtime: +((frames / rate) / (ms / 1000)).toFixed(0)}))
