// The bottom bar of the full-screen player: play and pause, the timeline, volume, and the keys.
// The video has no controls of its own there. `root` is the element holding the bar; `video`
// the <video>; `study` the hook, whose `abs()`, `total()` and `seekAbs()` keep the film's own
// clock (a stream may begin part-way through it). Returns nothing: it only listens.
import {formatTime, dialogueSpans} from "./cues.js"

const KEY = "roki:study:volume"

export function bindTransport(root, video, stage, study) {
  const $ = (sel) => root.querySelector(sel)
  const play = $("[data-role=play]")
  const seek = $("[data-role=seek]")
  const cur = $("[data-role=cur]")
  const dur = $("[data-role=dur]")
  const mute = $("[data-role=mute]")
  const volume = $("[data-role=volume]")
  let dragging = false

  const toggle = () => (video.paused ? video.play().catch(() => {}) : video.pause())
  const duration = () => study.total()

  const paint = (el, fraction) => el.style.setProperty("--p", `${Math.max(0, Math.min(1, fraction)) * 100}%`)
  const paint2 = (el, fraction) => el.style.setProperty("--b", `${Math.max(0, Math.min(1, fraction)) * 100}%`)

  const showPlaying = () => {
    play.querySelector("[data-icon=play]").classList.toggle("hidden", !video.paused)
    play.querySelector("[data-icon=pause]").classList.toggle("hidden", video.paused)
  }
  // How far ahead of where you are the video is already loaded: the end of the buffered range you
  // are in, on the film's clock (`abs()` adds the shift of a stream begun part-way through), as
  // `--b` on the bar, which paints it lighter than what is still to load. Nothing when the time is
  // in no buffered range (a seek still reading) or the length is unknown.
  // How much is loaded ahead, written above the current time ("+42s", "+1m 05s"): enough to tell
  // whether the picture will run on without a stop.
  const ahead = document.createElement("span")
  ahead.className = "study-ahead"
  ahead.title = "Loaded ahead of where you are"
  ahead.hidden = true
  seek.parentElement.append(ahead)
  const aheadText = (secs) => (secs < 60 ? `+${secs}s` : `+${Math.floor(secs / 60)}m ${String(secs % 60).padStart(2, "0")}s`)
  const showBuffered = (total = duration()) => {
    const b = video.buffered
    const t = video.currentTime
    let end = 0
    if (total > 0 && b) {
      for (let i = 0; i < b.length; i++) {
        if (b.start(i) <= t + 0.5 && t <= b.end(i) + 0.5) { end = b.end(i) + (study.shift || 0); break }
      }
    }
    paint2(seek, total > 0 ? end / total : 0)
    const secs = end > 0 ? Math.floor(end - (study.abs() || 0)) : 0
    ahead.hidden = !(total > 0 && secs >= 1)
    if (!ahead.hidden) ahead.textContent = aheadText(secs)
  }
  const showTime = () => {
    const total = duration()
    const now = study.abs() || 0
    cur.textContent = formatTime(now, total)
    dur.textContent = total ? formatTime(total) : "–:––"
    if (!dragging) {
      seek.value = total ? Math.round((now / total) * 1000) : 0
      paint(seek, total ? now / total : 0)
    }
    seek.disabled = !total
    showBuffered(total)
    drawTalk(total)
  }
  const showVolume = () => {
    volume.value = video.muted ? 0 : video.volume
    paint(volume, video.muted ? 0 : video.volume)
    mute.querySelector("[data-icon=on]").classList.toggle("hidden", video.muted || video.volume === 0)
    mute.querySelector("[data-icon=off]").classList.toggle("hidden", !(video.muted || video.volume === 0))
  }

  // Where people talk: thin white marks along the bottom of the bar, from the studied track's
  // lines (`study.p.cues`, moved by the sync offset). Drawn on a canvas laid over the bar and
  // redrawn only when something it depends on changes; `study.talk === false` switches it off.
  const talk = document.createElement("canvas")
  talk.className = "study-talk"
  talk.hidden = true
  talk.setAttribute("aria-hidden", "true")
  seek.parentElement.append(talk)
  let talkKey = ""
  const drawTalk = (total = duration()) => {
    const cues = study.p && study.p.cues
    const on = study.talk !== false && total > 0 && cues && cues.length > 0
    const box = seek.getBoundingClientRect()
    const dpr = window.devicePixelRatio || 1
    const key = on && box.width > 0
      ? [cues.length, cues[0].start, cues[cues.length - 1].end, study.offset || 0, Math.round(total), Math.round(box.width), Math.round(box.height), dpr, !!seek.closest("[data-look=sleek]")].join("|")
      : "off"
    if (key === talkKey) return
    talkKey = key
    talk.hidden = key === "off"
    if (talk.hidden) return
    const row = seek.parentElement.getBoundingClientRect()
    Object.assign(talk.style, {left: `${box.left - row.left}px`, top: `${box.top - row.top}px`, width: `${box.width}px`, height: `${box.height}px`})
    talk.width = Math.round(box.width * dpr)
    talk.height = Math.round(box.height * dpr)
    const ctx = talk.getContext("2d")
    ctx.clearRect(0, 0, talk.width, talk.height)
    // A strip a little above the bottom edge, so it reads as lines on the bar and not as its border.
    // The sleek bar's rail is hairline-thin: there the marks are a band down its middle, so they
    // sit the same on it at rest and swollen under the pointer.
    const sleek = !!seek.closest("[data-look=sleek]")
    const h = sleek ? Math.max(2 * dpr, Math.round(talk.height * 0.5)) : Math.max(2, Math.round(box.height * 0.16)) * dpr
    const y = sleek ? Math.round((talk.height - h) / 2) : talk.height - h - Math.max(2, Math.round(box.height * 0.14)) * dpr
    ctx.fillStyle = "rgb(255 255 255 / 0.6)"
    for (const [a, b] of dialogueSpans(cues, total, talk.width, study.offset || 0)) ctx.fillRect(a, y, Math.max(dpr, b - a), h)
  }
  study.redrawTalk = () => { talkKey = ""; drawTalk() }
  if (window.ResizeObserver) new ResizeObserver(() => drawTalk()).observe(seek)

  play.addEventListener("click", toggle)
  // A click that only closes a menu (audio, settings, subtitles…) must not also pause or play: whether one
  // was open is noted as the press begins, before the click closes it.
  let menuWasOpen = false
  root.addEventListener("pointerdown", () => { menuWasOpen = !!root.querySelector(".study-pop:not([hidden])") }, true)
  video.addEventListener("click", () => {
    if (menuWasOpen) { menuWasOpen = false; return }
    toggle()
  })
  video.addEventListener("dblclick", () => $("[data-role=fullscreen]")?.click())
  // A right click on the picture plays or pauses (not the browser's menu; not over the bar, a menu,
  // a word's card or a button, and only where there is a mouse: a long press on a phone is not it).
  stage.addEventListener("contextmenu", (e) => {
    if (!window.matchMedia("(pointer: fine)").matches) return
    if (e.target.closest(".study-controls, .study-pop, .study-tip, .study-close, button, a, input")) return
    e.preventDefault()
    toggle()
    root.dispatchEvent(new CustomEvent("roki:wake"))
  })
  for (const ev of ["play", "pause", "ended"]) video.addEventListener(ev, showPlaying)
  for (const ev of ["timeupdate", "durationchange", "loadedmetadata", "seeked"]) video.addEventListener(ev, showTime)
  // Loading goes on while paused, when no time updates come.
  video.addEventListener("progress", () => showBuffered())

  // Pointing at the timeline shows a thin white mark where a click would land, and the time there.
  const hover = document.createElement("div")
  hover.className = "study-hover"
  hover.hidden = true
  hover.innerHTML = '<span class="study-hover-time"></span>'
  // The mark lives in a clip laid exactly over the bar, so it is cut by the bar's rounded ends.
  const clip = document.createElement("div")
  clip.className = "study-hover-clip"
  clip.hidden = true
  clip.innerHTML = '<span class="study-hover-mark"></span>'
  seek.parentElement.append(clip, hover)
  const hoverTime = hover.firstChild
  const mark = clip.firstChild
  const showHover = (clientX, pointerType) => {
    const total = duration()
    if (!total || pointerType === "touch") return
    const box = seek.getBoundingClientRect()
    const x = Math.max(0, Math.min(box.width, clientX - box.left))
    // Placed from the bar's own box, so it sits on the bar whatever the padding around it.
    const row = seek.parentElement.getBoundingClientRect()
    hover.style.left = `${x + (box.left - row.left)}px`
    hover.style.top = `${box.top - row.top}px`
    hover.style.height = `${box.height}px`
    Object.assign(clip.style, {left: `${box.left - row.left}px`, top: `${box.top - row.top}px`, width: `${box.width}px`, height: `${box.height}px`})
    mark.style.left = `${x}px`
    clip.hidden = false
    hoverTime.textContent = formatTime((x / box.width) * total, total)
    hover.hidden = false
  }
  const hideHover = () => { hover.hidden = true; clip.hidden = true }
  seek.addEventListener("pointermove", (e) => showHover(e.clientX, e.pointerType))
  seek.addEventListener("pointerleave", hideHover)

  // A hit zone round the rail: the rail itself is a hairline in the sleek look, and to seek you had
  // to land on it. The zone is a taller, invisible strip laid over it. Pointing anywhere in it
  // swells the rail (`data-near` on the row, which the sleek CSS reads), and pressing in it seeks
  // and drags, exactly as pressing on the rail does (the input events it sends are the ones the
  // rail's own would be). The input stays under it for the keyboard and for screen readers.
  const row = seek.parentElement
  const zone = document.createElement("div")
  zone.className = "study-seek-zone"
  zone.setAttribute("aria-hidden", "true")
  row.append(zone)
  const placeZone = () => {
    const box = seek.getBoundingClientRect()
    const r = row.getBoundingClientRect()
    const h = Math.max(box.height, 36)
    Object.assign(zone.style, {
      left: `${box.left - r.left}px`, width: `${box.width}px`,
      top: `${box.top - r.top + box.height / 2 - h / 2}px`, height: `${h}px`,
    })
  }
  if (window.ResizeObserver) new ResizeObserver(placeZone).observe(seek)
  video.addEventListener("loadedmetadata", placeZone)
  placeZone()
  const seekTo = (clientX) => {
    const box = seek.getBoundingClientRect()
    const f = box.width > 0 ? Math.max(0, Math.min(1, (clientX - box.left) / box.width)) : 0
    seek.value = Math.round(f * 1000)
    seek.dispatchEvent(new Event("input", {bubbles: true}))
  }
  let pressed = false
  zone.addEventListener("pointerenter", () => { row.dataset.near = "" })
  zone.addEventListener("pointerleave", () => { if (!pressed) { delete row.dataset.near; hideHover() } })
  zone.addEventListener("pointerdown", (e) => {
    if (seek.disabled || e.button > 0) return
    pressed = true
    row.dataset.near = ""
    zone.setPointerCapture(e.pointerId)
    seekTo(e.clientX)
  })
  zone.addEventListener("pointermove", (e) => {
    if (pressed) seekTo(e.clientX)
    showHover(e.clientX, e.pointerType)
  })
  const release = (e) => {
    if (!pressed) return
    pressed = false
    seek.dispatchEvent(new Event("change", {bubbles: true}))
    if (!zone.matches(":hover")) { delete row.dataset.near; hideHover() }
  }
  zone.addEventListener("pointerup", release)
  zone.addEventListener("pointercancel", release)

  seek.addEventListener("input", () => {
    dragging = true
    const total = duration()
    paint(seek, seek.value / 1000)
    if (total) cur.textContent = formatTime((seek.value / 1000) * total, total)
  })
  seek.addEventListener("change", () => {
    dragging = false
    const total = duration()
    if (total) study.seekAbs((seek.value / 1000) * total)
  })

  mute.addEventListener("click", () => { video.muted = !video.muted })
  volume.addEventListener("input", () => {
    video.volume = Number(volume.value)
    video.muted = video.volume === 0
  })
  video.addEventListener("volumechange", () => {
    showVolume()
    try { localStorage.setItem(KEY, String(video.muted ? 0 : video.volume)) } catch {}
  })
  try {
    const saved = parseFloat(localStorage.getItem(KEY))
    if (Number.isFinite(saved)) video.volume = Math.max(0, Math.min(1, saved))
  } catch {}

  // Keys, unless something is being typed in.
  document.addEventListener("keydown", (e) => {
    // `;` and the space that carries on from study mode's own pause leave the bar as it is.
    if (!study.quietKey(e)) root.dispatchEvent(new CustomEvent("roki:wake"))
    if (e.metaKey || e.ctrlKey || e.altKey) return
    if (/^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) && e.target.type !== "range") return
    if (!root.isConnected) return
    const step = (s) => { study.seekAbs(Math.max(0, Math.min(duration() || Infinity, study.abs() + s))); stage.dataset.active = "1" }
    switch (e.key) {
      case " ": case "k": e.preventDefault(); toggle(); break
      case "ArrowLeft": e.preventDefault(); step(-5); break
      case "ArrowRight": e.preventDefault(); step(5); break
      case "j": step(-10); break
      case "l": step(10); break
      case "ArrowUp": e.preventDefault(); video.muted = false; video.volume = Math.min(1, video.volume + 0.05); break
      case "ArrowDown": e.preventDefault(); video.volume = Math.max(0, video.volume - 0.05); break
      case ",": if (!study.tools) return; study.stepLine(-1); stage.dataset.active = "1"; break
      case ".": if (!study.tools) return; study.stepLine(1); stage.dataset.active = "1"; break
      case "/": if (!study.tools) return; e.preventDefault(); study.replay(); stage.dataset.active = "1"; break
      case "c": { if (!study.tools) return; const b = $("[data-role=copy-line]"); if (b) study.copyWithNotice(b, study.linePrompt()); break }
      case ";": study.toggleTranslation(); break
      case "m": video.muted = !video.muted; break
      case "f": $("[data-role=fullscreen]")?.click(); break
      default: return
    }
  })

  showPlaying(); showTime(); showVolume()
}
