// Subtitle cues, and "which line is it now" — plain functions, no DOM, no libraries,
// so they can be tested on their own (`node --test assets/js/study/`).

// A cue timestamp: [hh:]mm:ss.mmm (WebVTT) or hh:mm:ss,mmm (SubRip). Hours are optional in VTT.
const TIME = /(?:(\d{1,}):)?(\d{2}):(\d{2})[.,](\d{3})/

const toSeconds = (m) => (m[1] ? Number(m[1]) * 3600 : 0) + Number(m[2]) * 60 + Number(m[3]) + Number(m[4]) / 1000

const ENTITIES = {"&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&#39;": "'", "&nbsp;": " ", "&lrm;": "", "&rlm;": ""}

// What a viewer should read: markup tags and ASS overrides removed, entities decoded.
export function cleanText(raw) {
  return raw
    .replace(/\{[^}]*\}/g, "")
    .replace(/<[^>]+>/g, "")
    .replace(/&(?:amp|lt|gt|quot|#39|nbsp|lrm|rlm);/g, (e) => ENTITIES[e])
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .join("\n")
}

// WebVTT (or SubRip, which differs only in the decimal comma and the header) → cues,
// `[{start, end, text}]`, sorted by start. Blocks that are not cues (the header, NOTE,
// STYLE, REGION) and cues with no text are skipped; a malformed block never throws.
export function parseVtt(vtt) {
  const blocks = String(vtt).replace(/^﻿/, "").replace(/\r\n?/g, "\n").split(/\n{2,}/)
  const cues = []

  for (const block of blocks) {
    const lines = block.split("\n")
    const at = lines.findIndex((l) => l.includes("-->"))
    if (at < 0) continue

    const [from, to] = lines[at].split("-->")
    const a = TIME.exec(from)
    const b = TIME.exec(to)
    if (!a || !b) continue

    const text = cleanText(lines.slice(at + 1).join("\n"))
    if (text) cues.push({start: toSeconds(a), end: toSeconds(b), text, order: cues.length})
  }

  // Stable: equal starts keep file order.
  cues.sort((x, y) => x.start - y.start || x.order - y.order)
  return cues.map(({start, end, text}) => ({start, end, text}))
}

// Index of the last cue that has started by `t` (so between lines it is the line you
// just heard), or -1 before the first. Cues must be sorted by start. O(log n): it runs
// every frame.
export function activeIndex(cues, t) {
  let lo = 0
  let hi = cues.length - 1
  let found = -1

  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    if (cues[mid].start <= t) {
      found = mid
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  return found
}

// Every cue being spoken at `t`: usually the active one, but two speakers can overlap,
// so the few cues before it are checked too. Ascending indexes; empty in a silence.
export function liveIndexes(cues, idx, t, lookback = 12) {
  const live = []
  for (let i = Math.max(0, idx - lookback); i <= idx; i++) {
    if (i >= 0 && cues[i].start <= t && t <= cues[i].end) live.push(i)
  }
  return live
}

// 83 → "1:23", 3725 → "1:02:05".
// `span` is the length of what is being timed: when it runs to an hour or more, every time is
// written with hours (0:01:37, not 1:37), so the clock at each end of the timeline is as wide as
// the other.
export function formatTime(seconds, span = 0) {
  const s = Math.max(0, Math.floor(seconds))
  const h = Math.floor(s / 3600)
  if (h === 0 && span >= 3600) return `0:${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`
  const m = Math.floor((s % 3600) / 60)
  const sec = String(s % 60).padStart(2, "0")
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`
}

// A line that is only a sound or music ("[door slams]", "(music)", "♪ la la ♪", "*"): not dialogue.
const NOISE = /\[[^\]]*\]|\([^)]*\)|[♪♫♬♩#*~\-–—.,…!?:;"'\s]/g
export function isDialogue(text) {
  const t = String(text || "")
  // A sung line ("♪ lyrics ♪") is music, whatever words it carries.
  if (/[♪♫♬♩]/.test(t)) return false
  return t.replace(NOISE, "") !== ""
}

// Where people talk, for drawing on a timeline `width` pixels wide that stands for `total`
// seconds: each spoken line becomes a span [x0, x1] in pixels, at least one pixel wide, moved by
// the sync `offset`, and spans that touch or overlap are merged. Lines past `total` (a film still
// being converted) are left out until the bar reaches them.
export function dialogueSpans(cues, total, width, offset = 0) {
  if (!(total > 0) || !(width > 0) || !cues || !cues.length) return []
  const k = width / total
  const spans = []
  for (const c of cues) {
    if (!isDialogue(c.text)) continue
    const a = c.start + offset
    const b = Math.max(c.end, c.start) + offset
    if (b <= 0 || a >= total) continue
    let x0 = Math.max(0, a) * k
    let x1 = Math.min(total, b) * k
    if (x1 - x0 < 1) x1 = Math.min(width, x0 + 1)
    const last = spans[spans.length - 1]
    if (last && x0 <= last[1] + 0.5) last[1] = Math.max(last[1], x1)
    else spans.push([x0, x1])
  }
  return spans
}

// Openings and credits, found where nobody talks (`cues`, moved by the sync `offset`) in a film
// `total` seconds long, as `[{kind: "intro" | "credits", from, to, tail}]` on the film's clock.
// `to` is where the next line begins (a second early), so a skip lands just before someone
// speaks; `tail` marks credits that run to the end with no line after them, which only a
// complete track can tell (`complete: false` leaves those out).
// - intro: the longest gap of 50–150 s that begins in the first ten minutes (or third);
// - credits: the last gap of 45–240 s in the last quarter that has a line after it (an
//   ending before a post-credits scene or a preview), and/or the silence from the last line
//   to the end when that is 30 s or more.
export function findSkips(cues, total, offset = 0, {complete = true} = {}) {
  const lines = (cues || [])
    .filter((c) => isDialogue(c.text))
    .map((c) => [c.start + offset, Math.max(c.end, c.start) + offset])
    .sort((a, b) => a[0] - b[0])
  if (lines.length < 10) return []
  const lastEnd = lines.reduce((m, l) => Math.max(m, l[1]), 0)
  const length = Math.max(total || 0, lastEnd)
  const gaps = []
  let reach = 0
  for (const [a, b] of lines) {
    if (a - reach > 0) gaps.push([reach, a])
    reach = Math.max(reach, b)
  }
  const out = []
  const intro = gaps
    .filter(([a, b]) => b - a >= 50 && b - a <= 150 && a < Math.min(600, length / 3))
    .sort((x, y) => (y[1] - y[0]) - (x[1] - x[0]))[0]
  if (intro) out.push({kind: "intro", from: intro[0], to: Math.max(intro[0], intro[1] - 1), tail: false})
  const ending = gaps
    .filter(([a, b]) => b - a >= 45 && b - a <= 240 && a >= length * 0.75 && a !== intro?.[0])
    .pop()
  if (ending) out.push({kind: "credits", from: ending[0], to: Math.max(ending[0], ending[1] - 1), tail: false})
  if (complete && total > 0 && total - lastEnd >= 30 && lastEnd >= total * 0.75)
    out.push({kind: "credits", from: lastEnd, to: total, tail: true})
  return out
}

// AniSkip's times (`[{kind: "op" | "ed", from, to, length}]`) for a file `total` seconds long.
// Times measured on a cut of another length belong to another file and are dropped; while the
// length is not known yet (a conversion still under way, `total` short of theirs) they are kept.
export function aniskipSkips(times, total) {
  const out = []
  for (const t of times || []) {
    const fits = !(t.length > 0) || !(total > 0) || Math.abs(t.length - total) <= 5 || total < t.length - 5
    if (!fits) continue
    const kind = t.kind === "op" ? "intro" : "credits"
    if (out.some((o) => o.kind === kind)) continue
    out.push({kind, from: t.from, to: t.to, tail: total > 0 && t.to >= total - 3})
  }
  return out
}

// The skip to offer at `now`: the first one that `now` is inside of, at least `settle` seconds
// in (a growing track may still fill a gap that is only not read yet) and more than two seconds
// from its end. `null` when there is none.
export function skipAt(skips, now, settle = 1.5) {
  return (skips || []).find((s) => now >= s.from + settle && now < s.to - 2) || null
}
