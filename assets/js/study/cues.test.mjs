// Run with: node --test assets/js/study/
import {test} from "node:test"
import assert from "node:assert/strict"
import {parseVtt, activeIndex, liveIndexes, formatTime, cleanText} from "./cues.js"

const VTT = `WEBVTT

NOTE a comment, not a cue

1
00:00:01.000 --> 00:00:03.500
Bonjour, <i>tout le monde</i>.

00:00:04.000 --> 00:00:06.000 align:start
Deuxième ligne
sur deux lignes

00:01:05.250 --> 00:01:07.000
Plus d'une minute &amp; demie
`

test("parses cues, strips markup, keeps line breaks, ignores non-cue blocks", () => {
  const cues = parseVtt(VTT)
  assert.equal(cues.length, 3)
  assert.deepEqual(cues[0], {start: 1, end: 3.5, text: "Bonjour, tout le monde."})
  assert.equal(cues[1].text, "Deuxième ligne\nsur deux lignes")
  assert.equal(cues[2].start, 65.25)
  assert.equal(cues[2].text, "Plus d'une minute & demie")
})

test("SubRip timestamps (comma) and hours work", () => {
  const cues = parseVtt("1\r\n01:02:03,500 --> 01:02:05,000\r\nUne heure\r\n")
  assert.deepEqual(cues, [{start: 3723.5, end: 3725, text: "Une heure"}])
})

test("cues come out sorted by start, equal starts keep file order", () => {
  const cues = parseVtt(`WEBVTT

00:00:05.000 --> 00:00:06.000
c

00:00:01.000 --> 00:00:02.000
a

00:00:01.000 --> 00:00:03.000
b
`)
  assert.deepEqual(cues.map((c) => c.text), ["a", "b", "c"])
})

test("a malformed block or an empty cue never throws and is skipped", () => {
  const cues = parseVtt(`WEBVTT

00:00:01.000 --> nonsense
broken

00:00:02.000 --> 00:00:03.000
<i></i>

00:00:04.000 --> 00:00:05.000
fine
`)
  assert.deepEqual(cues.map((c) => c.text), ["fine"])
  assert.deepEqual(parseVtt(""), [])
  assert.deepEqual(parseVtt("not a subtitle file at all"), [])
})

test("a byte-order mark does not hide the first cue", () => {
  assert.equal(parseVtt("﻿WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n").length, 1)
})

test("ASS override tags are removed", () => {
  assert.equal(cleanText("{\\an8}{\\i1}Haut{\\i0}"), "Haut")
})

const cues = [
  {start: 1, end: 3, text: "a"},
  {start: 4, end: 6, text: "b"},
  {start: 10, end: 12, text: "c"},
]

test("activeIndex: before the first, inside, in a gap, after the last", () => {
  assert.equal(activeIndex(cues, 0), -1)
  assert.equal(activeIndex(cues, 1), 0)
  assert.equal(activeIndex(cues, 2.9), 0)
  assert.equal(activeIndex(cues, 3.5), 0) // a gap: still the line you just heard
  assert.equal(activeIndex(cues, 4), 1)
  assert.equal(activeIndex(cues, 11), 2)
  assert.equal(activeIndex(cues, 999), 2)
  assert.equal(activeIndex([], 5), -1)
})

test("activeIndex agrees with a linear scan everywhere (binary search is right)", () => {
  const many = Array.from({length: 500}, (_, i) => ({start: i * 2.5, end: i * 2.5 + 2, text: String(i)}))
  for (let t = -1; t < 1300; t += 0.37) {
    let expected = -1
    for (let i = 0; i < many.length; i++) if (many[i].start <= t) expected = i
    assert.equal(activeIndex(many, t), expected, `t=${t}`)
  }
})

test("liveIndexes: the spoken line, none in a silence, both when two overlap", () => {
  assert.deepEqual(liveIndexes(cues, activeIndex(cues, 2), 2), [0])
  assert.deepEqual(liveIndexes(cues, activeIndex(cues, 3.5), 3.5), [])
  assert.deepEqual(liveIndexes(cues, activeIndex(cues, 0), 0), [])

  const overlap = [
    {start: 1, end: 5, text: "x"},
    {start: 2, end: 3, text: "y"},
  ]
  assert.deepEqual(liveIndexes(overlap, activeIndex(overlap, 2.5), 2.5), [0, 1])
  assert.deepEqual(liveIndexes(overlap, activeIndex(overlap, 4), 4), [0])
})

test("formatTime", () => {
  assert.equal(formatTime(0), "0:00")
  assert.equal(formatTime(83.9), "1:23")
  assert.equal(formatTime(3725), "1:02:05")
  assert.equal(formatTime(-5), "0:00")
})
