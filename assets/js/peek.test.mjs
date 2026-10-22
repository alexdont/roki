import test from "node:test"
import assert from "node:assert/strict"

// peek.js touches `document` only inside functions, so the helper can be imported on its own.
const {released} = await import("./peek.js")

const iso = (offset) => {
  const d = new Date()
  d.setDate(d.getDate() + offset)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`
}

test("a film already out says when, in grey words, and how long ago", () => {
  assert.match(released(iso(-233), "movie/1"), /^Released \d{1,2} \w{3} \d{4} \(233 days ago\)$/)
})

test("a show says first aired", () => {
  assert.match(released(iso(-5), "tv/1"), /^First aired .* \(5 days ago\)$/)
})

test("yesterday and today are words, large numbers get separators", () => {
  assert.match(released(iso(-1), "movie/1"), /\(yesterday\)$/)
  assert.match(released(iso(0), "movie/1"), /\(today\)$/)
  assert.match(released("1968-10-01", "movie/1"), /\(\d{2},\d{3} days ago\)$/)
})

test("nonsense gives nothing", () => {
  assert.equal(released("soon"), "")
})
