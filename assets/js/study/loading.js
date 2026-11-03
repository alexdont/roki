// What the player is waiting for, over the picture: from Play to the first frame (connecting,
// reading the file's length and tracks, loading the first seconds — with how much has arrived,
// how fast, how long is left), a conversion catching up to where you left off, a read from a new
// place, and a stall mid-film. Without it the stage is black and there is no telling whether
// anything is happening. `describe` is the pure part (tested); `bindLoading` keeps the numbers.
import {formatTime} from "./cues.js"

export function formatBytes(n) {
  if (!(n > 0)) return "0 MB"
  if (n < 1e6) return `${Math.max(1, Math.round(n / 1e3))} KB`
  if (n < 1e9) return `${(n / 1e6).toFixed(n < 1e7 ? 1 : 0)} MB`
  return `${(n / 1e9).toFixed(2)} GB`
}

export function formatRate(bytesPerSecond) {
  if (!(bytesPerSecond > 0)) return null
  return `${formatBytes(bytesPerSecond)}/s`
}

// "about 4 s", "about 2 min".
export function formatWait(s) {
  if (!Number.isFinite(s) || s < 0) return null
  if (s < 1) return "almost there"
  if (s < 90) return `about ${Math.ceil(s)} s`
  return `about ${Math.round(s / 60)} min`
}

const TITLES = {
  connect: "Connecting to the source",
  header: "Reading the file’s length and tracks",
  first: "Loading the first seconds",
}

/**
 * `s`: a snapshot — `starting` (no frame yet), `phase` (connect / header / first), `elapsed` (s),
 * `bytes` (arrived so far), `rate` (bytes/s), `part` ({loaded, total} of what is loading now),
 * `ahead` (seconds ready past the playhead), `catchup` ({target, reach, rate} on the film's clock),
 * `seekTo` (a read from a new place), `stalled` (ms waiting mid-film), `paused`,
 * `deadline` (s until the page gives up on this source), `from` (where in the film it starts).
 * Returns `{title, detail, fraction}` (fraction null when unknown), or null: nothing to show.
 */
export function describe(s) {
  const join = (...xs) => xs.filter(Boolean).join(" · ")
  const speed = formatRate(s.rate)

  if (s.seekTo != null) {
    return {title: `Loading from ${formatTime(s.seekTo)}`, detail: join(speed), fraction: null}
  }

  if (s.catchup) {
    const {target, reach, rate} = s.catchup
    const left = target - reach
    return {
      title: "Preparing the video up to where you left off",
      detail: join(`${formatTime(Math.max(0, reach))} of ${formatTime(target)} ready`, rate > 0 ? formatWait(left / rate) : null),
      fraction: target > 0 ? Math.max(0, Math.min(1, reach / target)) : null,
    }
  }

  if (s.starting) {
    const part = s.part && s.part.total > 0 ? s.part : null
    const eta = part && s.rate > 0 ? formatWait((part.total - part.loaded) / s.rate) : null
    const arrived = part ? `${formatBytes(part.loaded)} of ${formatBytes(part.total)}` : s.bytes > 0 ? `${formatBytes(s.bytes)} read` : null
    const giveUp = s.deadline != null && s.deadline <= 15 ? `another source in ${Math.max(0, Math.ceil(s.deadline))} s` : null
    const from = s.phase !== "connect" && s.phase !== "header" && s.from > 5 ? `Loading from ${formatTime(s.from)}` : null
    return {
      title: from || TITLES[s.phase] || TITLES.first,
      detail: join(arrived, speed, eta, giveUp || `waiting ${Math.floor(s.elapsed || 0)} s`),
      fraction: part ? Math.max(0, Math.min(1, part.loaded / part.total)) : null,
    }
  }

  if (s.stalled != null && s.stalled >= 600 && !s.paused) {
    return {title: "Loading", detail: join(speed), fraction: null}
  }

  return null
}

// The overlay, and the numbers behind it. The page tells it what happens (`begin`, `phase`,
// `partStart`/`partDone` for hls.js fragments, `read` for the device player's reads); the rest it
// reads off the video. `study` is the StudySidebar hook (`local`, `catchup`, `abs`).
export function bindLoading(stage, video, study) {
  const el = document.createElement("div")
  el.className = "study-loading"
  el.hidden = true
  el.setAttribute("role", "status")
  el.innerHTML = `<span class="study-loading-spin"></span><div class="study-loading-text"><strong></strong><span></span></div><div class="study-loading-bar" hidden><i></i></div>`
  stage.appendChild(el)
  const [titleEl, detailEl] = el.querySelectorAll(".study-loading-text > *")
  const bar = el.querySelector(".study-loading-bar")
  const fill = bar.firstElementChild

  let st = null // this source's start
  let waitingSince = null
  let wasSeeking = false
  let landing = null // where that read went, until the picture is there
  let catchSamples = []
  let samples = [] // [ms, bytes], the last few seconds, for the speed

  const bytes = () => st ? st.done + [...st.parts].reduce((n, p) => n + (p.loaded || 0), 0) : 0

  const rate = (list, now) => {
    const recent = list.filter(([t]) => now - t <= 4000)
    if (recent.length < 2) return 0
    const [t0, b0] = recent[0]
    const [t1, b1] = recent[recent.length - 1]
    return t1 - t0 >= 1000 ? ((b1 - b0) * 1000) / (t1 - t0) : 0
  }

  // A video ready to play has started; one ready and paused was refused autoplay, and the
  // controls are there for it.
  const settle = () => {
    if (st && st.starting && video.readyState >= 3 && (!video.paused || video.currentTime > 0 || st.playRefused)) st.starting = false
  }

  video.addEventListener("playing", () => { if (st) st.starting = false; waitingSince = null; render() })
  video.addEventListener("waiting", () => { if (waitingSince == null) waitingSince = performance.now() })
  for (const ev of ["canplay", "pause", "seeked", "timeupdate"]) {
    video.addEventListener(ev, () => {
      if (ev !== "timeupdate" || !video.paused) { if (video.readyState >= 3) waitingSince = null }
      settle()
    })
  }

  const render = () => {
    const now = performance.now()
    if (st) samples.push([now, bytes()])
    samples = samples.filter(([t]) => now - t <= 5000)

    const local = study.local
    const catchup = study.catchup
    // A read from a new place has landed but the picture is not there yet: no gap between the two.
    const seeking = !!(local && local.seeking)
    if (wasSeeking && !seeking && video.readyState < 3) { waitingSince = Math.min(waitingSince ?? now, now - 600); landing = wasSeeking }
    if (seeking || waitingSince == null) landing = null
    // (the target of the read under way, kept for the moment it lands)
    wasSeeking = seeking ? local.target ?? true : false
    if (catchup) {
      catchSamples.push([now, catchup.reach])
      catchSamples = catchSamples.filter(([t]) => now - t <= 8000)
    } else catchSamples = []

    const b = video.buffered
    let ahead = 0
    for (let i = 0; b && i < b.length; i++) if (b.start(i) <= video.currentTime + 0.5 && video.currentTime <= b.end(i)) ahead = b.end(i) - video.currentTime

    const part = st && st.parts.size ? [...st.parts].reduce((a, p) => ({loaded: a.loaded + (p.loaded || 0), total: a.total + (p.total || 0)}), {loaded: 0, total: 0}) : null

    const shown = describe({
      starting: !!(st && st.starting),
      phase: st && st.phase,
      elapsed: st ? (now - st.at) / 1000 : 0,
      bytes: bytes(),
      rate: rate(samples, now),
      part: part && part.total >= part.loaded ? part : null,
      ahead,
      catchup: catchup ? {...catchup, rate: rate(catchSamples, now)} : null,
      seekTo: seeking ? local.target : typeof landing === "number" ? landing : null,
      stalled: waitingSince == null ? null : now - waitingSince,
      paused: video.paused,
      deadline: st && st.startup ? (st.at + st.startup - now) / 1000 : null,
      from: st ? st.from : 0,
    })

    el.hidden = !shown
    if (!shown) return
    titleEl.textContent = shown.title
    detailEl.textContent = shown.detail
    bar.hidden = shown.fraction == null
    if (shown.fraction != null) fill.style.width = `${(shown.fraction * 100).toFixed(1)}%`
  }

  const timer = setInterval(render, 250)

  return {
    // A new source: `local` starts by reading the file's length and tracks, a stream by connecting.
    begin({startup = null, local = false, from = 0} = {}) {
      st = {at: performance.now(), phase: local ? "header" : "connect", starting: true, startup, from, done: 0, parts: new Set(), playRefused: false}
      samples = []
      waitingSince = null
      render()
    },
    phase(name) { if (st) { st.phase = name; render() } },
    // The play() promise was refused (no gesture): once ready, the overlay leaves it to the controls.
    playRefused() { if (st) { st.playRefused = true; settle() } },
    // hls.js fragments: their `stats` object, which the loader updates as bytes arrive.
    partStart(stats) { if (st && st.starting && stats) st.parts.add(stats) },
    partDone(stats) {
      if (!st || !stats) return
      if (st.parts.delete(stats) || !st.starting) st.done += stats.loaded || stats.total || 0
    },
    // The device player's reads of the file.
    read(n) { if (st && n > 0) st.done += n },
    stop() { clearInterval(timer); el.remove() },
  }
}
