import { test } from "node:test"
import assert from "node:assert/strict"
globalThis.window = globalThis.window || { addEventListener() {}, matchMedia: () => ({ matches: false, addEventListener() {} }) }
globalThis.document = globalThis.document || { addEventListener() {}, createElement: () => ({ style: {}, classList: { add() {} }, setAttribute() {}, append() {} }), querySelector: () => null, documentElement: { dataset: {} } }
globalThis.localStorage = { getItem: () => null, setItem() {} }
const { StudySidebar } = await import("./sidebar.js")

function fakeVideo() {
  const ls = {}
  const v = { currentTime: 0, addEventListener: (n, f) => ((ls[n] ||= []).push(f)) }
  v.fire = (n) => (ls[n] || []).forEach((f) => f())
  // A seek: setting currentTime fires seeking then (unless told otherwise) seeked.
  v.seek = (t, landAt = t) => { v.currentTime = t; v.fire("seeking"); v.currentTime = landAt; v.fire("seeked") }
  return v
}
const hook = (v) => { const h = Object.create(StudySidebar); h.video = v; h.local = null; h.shift = 0; h.guardSeeks(); return h }
const wait = (ms) => new Promise((r) => setTimeout(r, ms))

test("the phone's own control seeks far in, Safari throws it to 0:00: asked again", async () => {
  const v = fakeVideo(); const h = hook(v)
  v.seek(1200, 0)
  await wait(450)
  assert.equal(v.currentTime, 1200)
})

test("Safari's snap back comes as a seek of its own: the aim is kept", async () => {
  const v = fakeVideo(); const h = hook(v)
  v.seek(1200, 1200)            // landed
  v.seek(0, 0)                  // Safari's snap, a second later
  await wait(450)
  assert.equal(v.currentTime, 1200)
})

test("a deliberate seek to the start, well after, is left alone", async () => {
  const v = fakeVideo(); const h = hook(v)
  v.seek(1200, 1200)
  h.lastAsk.at -= 6000          // six seconds ago
  v.seek(0, 0)
  await wait(450)
  assert.equal(v.currentTime, 0)
})

test("the page's own seek keeps working as before", async () => {
  const v = fakeVideo(); const h = hook(v)
  h.landAt(900); v.fire("seeking"); v.currentTime = 0; v.fire("seeked")
  await wait(450)
  assert.equal(v.currentTime, 900)
})
