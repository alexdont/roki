import test from "node:test"
import assert from "node:assert/strict"

// A stand-in for the browser's storage.
const store = new Map()
globalThis.localStorage = {getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v))}
const {lengths} = await import("./lengths.js")

test("a length is kept per file and comes back", () => {
  store.clear()
  assert.equal(lengths.get("a:100"), null)
  lengths.set("a:100", 5421.3)
  assert.equal(lengths.get("a:100"), 5421.3)
  assert.equal(lengths.get("a:101"), null) // the same release at another size is another file
})

test("nonsense is not kept, and no key is no memory", () => {
  store.clear()
  lengths.set("k", NaN); lengths.set("k", 0); lengths.set("k", -3); lengths.set(null, 100)
  assert.equal(lengths.get("k"), null)
  assert.equal(lengths.get(null), null)
})

test("only the newest few hundred are kept", () => {
  store.clear()
  for (let i = 0; i < 320; i++) lengths.set(`f${i}`, 100 + i)
  assert.equal(lengths.get("f0"), null)
  assert.equal(lengths.get("f319"), 419)
  assert.ok(Object.keys(JSON.parse(store.get("roki:lengths"))).length <= 300)
})

test("a broken store is no memory, not an error", () => {
  store.set("roki:lengths", "{not json")
  assert.equal(lengths.get("x"), null)
  lengths.set("x", 60)
  assert.equal(lengths.get("x"), 60)
})
