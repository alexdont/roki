import test from "node:test"
import assert from "node:assert/strict"
import {visibleCount} from "./fill_grid.js"

test("while there is more to load, only whole rows are shown", () => {
  assert.equal(visibleCount(20, 6, true), 18)
  assert.equal(visibleCount(40, 6, true), 36)
  assert.equal(visibleCount(20, 4, true), 20)
  assert.equal(visibleCount(20, 8, true), 16)
})

test("at the end everything is shown, however the last row falls", () => {
  assert.equal(visibleCount(20, 6, false), 20)
})

test("a grid with fewer posters than columns is left alone", () => {
  assert.equal(visibleCount(3, 6, true), 3)
  assert.equal(visibleCount(0, 6, true), 0)
})
