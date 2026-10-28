// The bottom bar of the full-screen player: play and pause, the timeline, volume, and the keys.
// The video has no controls of its own there. `root` is the element holding the bar; `video`
// the <video>; `study` the hook, whose `abs()`, `total()` and `seekAbs()` keep the film's own
// clock (a stream may begin part-way through it). Returns nothing: it only listens.
import {formatTime} from "./cues.js"

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

  const showPlaying = () => {
    play.querySelector("[data-icon=play]").classList.toggle("hidden", !video.paused)
    play.querySelector("[data-icon=pause]").classList.toggle("hidden", video.paused)
  }
  const showTime = () => {
    const total = duration()
    const now = study.abs() || 0
    cur.textContent = formatTime(now)
    dur.textContent = total ? formatTime(total) : "–:––"
    if (!dragging) {
      seek.value = total ? Math.round((now / total) * 1000) : 0
      paint(seek, total ? now / total : 0)
    }
    seek.disabled = !total
  }
  const showVolume = () => {
    volume.value = video.muted ? 0 : video.volume
    paint(volume, video.muted ? 0 : video.volume)
    mute.querySelector("[data-icon=on]").classList.toggle("hidden", video.muted || video.volume === 0)
    mute.querySelector("[data-icon=off]").classList.toggle("hidden", !(video.muted || video.volume === 0))
  }

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
  for (const ev of ["play", "pause", "ended"]) video.addEventListener(ev, showPlaying)
  for (const ev of ["timeupdate", "durationchange", "loadedmetadata", "seeked"]) video.addEventListener(ev, showTime)

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
  seek.addEventListener("pointermove", (e) => {
    const total = duration()
    if (!total || e.pointerType === "touch") return
    const box = seek.getBoundingClientRect()
    const x = Math.max(0, Math.min(box.width, e.clientX - box.left))
    // Placed from the bar's own box, so it sits on the bar whatever the padding around it.
    const row = seek.parentElement.getBoundingClientRect()
    hover.style.left = `${x + (box.left - row.left)}px`
    hover.style.top = `${box.top - row.top}px`
    hover.style.height = `${box.height}px`
    Object.assign(clip.style, {left: `${box.left - row.left}px`, top: `${box.top - row.top}px`, width: `${box.width}px`, height: `${box.height}px`})
    mark.style.left = `${x}px`
    clip.hidden = false
    hoverTime.textContent = formatTime((x / box.width) * total)
    hover.hidden = false
  })
  seek.addEventListener("pointerleave", () => { hover.hidden = true; clip.hidden = true })

  seek.addEventListener("input", () => {
    dragging = true
    const total = duration()
    paint(seek, seek.value / 1000)
    if (total) cur.textContent = formatTime((seek.value / 1000) * total)
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
  if (!(study.flags && study.flags.get("novol") === "1")) try {
    const saved = parseFloat(localStorage.getItem(KEY))
    if (Number.isFinite(saved)) video.volume = Math.max(0, Math.min(1, saved))
  } catch {}

  // Keys, unless something is being typed in.
  document.addEventListener("keydown", (e) => {
    root.dispatchEvent(new CustomEvent("roki:wake"))
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
      case "m": video.muted = !video.muted; break
      case "f": $("[data-role=fullscreen]")?.click(); break
      default: return
    }
  })

  showPlaying(); showTime(); showVolume()
}
