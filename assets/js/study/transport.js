// The bottom bar of the full-screen player: play and pause, the timeline, volume, and the keys.
// The video has no controls of its own there. `root` is the element holding the bar; `video`
// the <video>. Returns nothing: it only listens.
import {formatTime} from "./cues.js"

const KEY = "roki:study:volume"

export function bindTransport(root, video, stage) {
  const $ = (sel) => root.querySelector(sel)
  const play = $("[data-role=play]")
  const seek = $("[data-role=seek]")
  const cur = $("[data-role=cur]")
  const dur = $("[data-role=dur]")
  const mute = $("[data-role=mute]")
  const volume = $("[data-role=volume]")
  let dragging = false

  const toggle = () => (video.paused ? video.play().catch(() => {}) : video.pause())
  const duration = () => (Number.isFinite(video.duration) ? video.duration : 0)

  const paint = (el, fraction) => el.style.setProperty("--p", `${Math.max(0, Math.min(1, fraction)) * 100}%`)

  const showPlaying = () => {
    play.querySelector("[data-icon=play]").classList.toggle("hidden", !video.paused)
    play.querySelector("[data-icon=pause]").classList.toggle("hidden", video.paused)
  }
  const showTime = () => {
    const total = duration()
    cur.textContent = formatTime(video.currentTime || 0)
    dur.textContent = total ? formatTime(total) : "–:––"
    if (!dragging) {
      seek.value = total ? Math.round((video.currentTime / total) * 1000) : 0
      paint(seek, total ? video.currentTime / total : 0)
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
  video.addEventListener("click", toggle)
  video.addEventListener("dblclick", () => $("[data-role=fullscreen]")?.click())
  for (const ev of ["play", "pause", "ended"]) video.addEventListener(ev, showPlaying)
  for (const ev of ["timeupdate", "durationchange", "loadedmetadata", "seeked"]) video.addEventListener(ev, showTime)

  seek.addEventListener("input", () => {
    dragging = true
    const total = duration()
    paint(seek, seek.value / 1000)
    if (total) cur.textContent = formatTime((seek.value / 1000) * total)
  })
  seek.addEventListener("change", () => {
    dragging = false
    const total = duration()
    if (total) video.currentTime = (seek.value / 1000) * total
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
    if (e.metaKey || e.ctrlKey || e.altKey) return
    if (/^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) && e.target.type !== "range") return
    if (!root.isConnected) return
    const step = (s) => { video.currentTime = Math.max(0, Math.min(duration() || Infinity, video.currentTime + s)); stage.dataset.active = "1" }
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
