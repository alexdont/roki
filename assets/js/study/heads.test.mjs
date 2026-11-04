import test from "node:test"
import assert from "node:assert/strict"
import {makeHeads} from "./heads.js"

// A stand-in for the browser's Cache storage and localStorage.
function fakes() {
  const entries = new Map()
  const cache = {
    async match(u) { return entries.get(u) || undefined },
    async put(u, res) { entries.set(u, res) },
    async keys() { return [...entries.keys()].map((u) => ({url: u})) },
    async delete(req) { entries.delete(req.url) },
  }
  const kv = new Map()
  return {
    entries,
    caches: {open: async () => cache},
    storage: {getItem: (k) => (kv.has(k) ? kv.get(k) : null), setItem: (k, v) => kv.set(k, String(v))},
  }
}
globalThis.Response = class {
  constructor(body, init) {
    this.body = body
    const h = (init && init.headers) || {}
    this.headers = {get: (k) => (k in h ? h[k] : null)}
  }
  async arrayBuffer() { return this.body.buffer.slice(this.body.byteOffset, this.body.byteOffset + this.body.byteLength) }
}

test("a read kept comes back, by file and range, with its offset", async () => {
  const f = fakes(), h = makeHeads(f)
  assert.equal(await h.get("f1", 0, 1024), null)
  await h.put("f1", 0, 1024, {offset: 0, bytes: new Uint8Array([1, 2, 3])})
  const back = await h.get("f1", 0, 1024)
  assert.deepEqual([...back.bytes], [1, 2, 3])
  assert.equal(back.offset, 0)
  assert.equal(await h.get("f1", 0, 2048), null) // another range
  assert.equal(await h.get("f2", 0, 1024), null) // another file
  assert.deepEqual(h.stats(), {files: 1, bytes: 3})
})

test("a file keeps no more than its share; the oldest files go when the store is full", async () => {
  // Small caps for the test: 60 a file, 300 in all, 24 a read.
  const f = fakes(), h = makeHeads({...f, perFile: 60, inAll: 300, perRead: 24})
  const big = new Uint8Array(20)
  for (let i = 0; i < 4; i++) await h.put("a", i * 100, i * 100 + 1, {offset: i * 100, bytes: big}) // 80 asked, 60 kept
  assert.equal(h.stats().bytes, 60)
  // a sixth file of 60 would make 320 > 300, so the oldest (a) goes as it is put
  for (const k of ["b", "c", "d", "e"]) { for (let i = 0; i < 3; i++) await h.put(k, i, i + 1, {offset: i, bytes: big}) }
  assert.equal(h.stats().files, 5)
  await h.put("f", 0, 1, {offset: 0, bytes: big})
  assert.equal(await h.get("a", 0, 1), null)
  assert.ok(h.stats().bytes <= 300)
  assert.ok(await h.get("f", 0, 1))
  // a read over the per-read cap is not kept at all
  await h.put("f", 5, 6, {offset: 5, bytes: new Uint8Array(25)})
  assert.equal(await h.get("f", 5, 6), null)
})

test("no storage is no memory, and no error", async () => {
  const h = makeHeads({caches: null, storage: null})
  assert.equal(await h.get("x", 0, 1), null)
  await h.put("x", 0, 1, {offset: 0, bytes: new Uint8Array(3)})
  assert.deepEqual(h.stats(), {files: 0, bytes: 0})
})
