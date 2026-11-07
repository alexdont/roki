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
  assert.equal(formatTime(97, 6480), "0:01:37")
  assert.equal(formatTime(97, 1200), "1:37")
  assert.equal(formatTime(3725, 6480), "1:02:05")
  assert.equal(formatTime(0), "0:00")
  assert.equal(formatTime(83.9), "1:23")
  assert.equal(formatTime(3725), "1:02:05")
  assert.equal(formatTime(-5), "0:00")
})

test("isDialogue: sounds and music are not dialogue", async () => {
  const {isDialogue} = await import("./cues.js")
  assert.equal(isDialogue("Hello there."), true)
  assert.equal(isDialogue("[door slams]"), false)
  assert.equal(isDialogue("(MUSIC PLAYING)"), false)
  assert.equal(isDialogue("♪ ♪"), false)
  assert.equal(isDialogue("- [gasps]\n- What?"), true)
  assert.equal(isDialogue("こんにちは"), true)
  assert.equal(isDialogue(""), false)
})

test("dialogueSpans: scales, offsets, merges, skips noise and what is past the end", async () => {
  const {dialogueSpans} = await import("./cues.js")
  const cues = [
    {start: 10, end: 20, text: "a"},
    {start: 20, end: 30, text: "b"},     // touches the first: merged
    {start: 40, end: 40.01, text: "c"},  // shorter than a pixel: one pixel
    {start: 50, end: 60, text: "[music]"},
    {start: 90, end: 120, text: "d"},    // runs past the end: cut
    {start: 150, end: 160, text: "e"},   // past the end: gone
  ]
  assert.deepEqual(dialogueSpans(cues, 100, 100), [[10, 30], [40, 41], [90, 100]])
  assert.deepEqual(dialogueSpans(cues, 100, 100, 5).slice(0, 1), [[15, 35]])
  assert.deepEqual(dialogueSpans(cues, 0, 100), [])
  assert.deepEqual(dialogueSpans([], 100, 100), [])
})

// An episode of 24 minutes: a cold open, a 90 s opening, talk, the ending, a preview, silence.
const episode = () => {
  const cues = []
  const talk = (from, to) => { for (let s = from; s < to; s += 6) cues.push({start: s, end: s + 4, text: "line"}) }
  talk(5, 95)           // cold open, last line ends 4 s after 89
  cues.push({start: 120, end: 124, text: "♪ opening ♪"})
  talk(190, 1200)       // first half, the middle, the second half
  talk(1300, 1340)      // the preview after the ending
  return cues
}

test("findSkips: the opening, the ending before a preview, and the silent end", async () => {
  const {findSkips} = await import("./cues.js")
  const skips = findSkips(episode(), 1440)
  const intro = skips.find((s) => s.kind === "intro")
  assert.ok(intro && intro.from === 93 && intro.to === 189)
  const mid = skips.find((s) => s.kind === "credits" && !s.tail)
  assert.ok(mid && mid.to === 1299)
  const tail = skips.find((s) => s.tail)
  assert.ok(tail && tail.to === 1440)
  assert.equal(findSkips(episode(), 1440, 0, {complete: false}).some((s) => s.tail), false)
})

test("findSkips: a film that never stops talking has nothing to skip; too few lines, nothing", async () => {
  const {findSkips} = await import("./cues.js")
  const cues = []
  for (let s = 0; s < 6000; s += 8) cues.push({start: s, end: s + 5, text: "x"})
  assert.deepEqual(findSkips(cues, 6010), [])
  assert.deepEqual(findSkips(cues.slice(0, 5), 6010), [])
})

test("findSkips: the sync offset moves the gaps", async () => {
  const {findSkips} = await import("./cues.js")
  const intro = findSkips(episode(), 1440, 10).find((s) => s.kind === "intro")
  assert.equal(intro.from, 103)
})

test("aniskipSkips: keeps times measured on this cut, drops another cut's", async () => {
  const {aniskipSkips} = await import("./cues.js")
  const times = [
    {kind: "op", from: 54.7, to: 145.1, length: 1435.1},
    {kind: "ed", from: 1338.3, to: 1428.3, length: 1435.0},
    {kind: "ed", from: 224, to: 314, length: 1492.2},
  ]
  const s = aniskipSkips(times, 1436)
  assert.deepEqual(s.map((x) => x.kind), ["intro", "credits"])
  assert.equal(s[1].from, 1338.3)
  assert.equal(aniskipSkips(times, 1300).length, 2) // still converting: kept
  assert.equal(aniskipSkips(times, 1600).length, 0) // another cut
})

test("skipAt: only inside, after settling, not at the very end", async () => {
  const {skipAt} = await import("./cues.js")
  const skips = [{kind: "intro", from: 100, to: 190}]
  assert.equal(skipAt(skips, 100.5), null)
  assert.equal(skipAt(skips, 102).kind, "intro")
  assert.equal(skipAt(skips, 189), null)
  assert.equal(skipAt(skips, 50), null)
})
