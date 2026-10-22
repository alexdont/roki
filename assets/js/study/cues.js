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
export function formatTime(seconds) {
  const s = Math.max(0, Math.floor(seconds))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = String(s % 60).padStart(2, "0")
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`
}
