import {test} from "node:test"
import assert from "node:assert/strict"
import {describe, formatBytes, formatWait} from "./loading.js"

test("nothing to show once it plays", () => {
  assert.equal(describe({starting: false, stalled: null, paused: false}), null)
})

test("starting: the step, what has arrived, the speed, what is left", () => {
  const s = describe({starting: true, phase: "first", elapsed: 3.4, rate: 2e6, part: {loaded: 3e6, total: 7e6}})
  assert.equal(s.title, "Loading the first seconds")
  assert.equal(s.detail, "3.0 MB of 7.0 MB · 2.0 MB/s · about 2 s · waiting 3 s")
  assert.ok(Math.abs(s.fraction - 3 / 7) < 1e-9)
})

test("reading the file's length: bytes read, no bar", () => {
  const s = describe({starting: true, phase: "header", elapsed: 12, bytes: 4.2e6})
  assert.match(s.title, /length/)
  assert.equal(s.detail, "4.2 MB read · waiting 12 s")
  assert.equal(s.fraction, null)
})

test("the last 15 s before another source is tried say so", () => {
  assert.match(describe({starting: true, phase: "connect", elapsed: 14, deadline: 11.2}).detail, /another source in 12 s/)
  assert.doesNotMatch(describe({starting: true, phase: "connect", elapsed: 4, deadline: 21}).detail, /another source/)
})

test("a conversion catching up to where you left off", () => {
  const s = describe({catchup: {target: 3600, reach: 1800, rate: 10}})
  assert.equal(s.detail, "30:00 of 1:00:00 ready · about 3 min")
  assert.equal(s.fraction, 0.5)
})

test("a stall mid-film shows after a moment, not while paused", () => {
  assert.equal(describe({stalled: 300, paused: false}), null)
  assert.equal(describe({stalled: 900, paused: true}), null)
  assert.equal(describe({stalled: 900, paused: false, rate: 1.5e6, ahead: 0.2}).detail, "1.5 MB/s")
})

test("resuming says where from, once the file is open", () => {
  assert.equal(describe({starting: true, phase: "first", from: 4052}).title, "Loading from 1:07:32")
  assert.match(describe({starting: true, phase: "header", from: 4052}).title, /length/)
})

test("formats", () => {
  assert.equal(formatBytes(512e3), "512 KB")
  assert.equal(formatBytes(48.3e6), "48 MB")
  assert.equal(formatWait(0.4), "almost there")
  assert.equal(formatWait(130), "about 2 min")
})
