// The study sidebar: every subtitle line, the live one highlighted, kept in view while
// you watch — and left alone the moment you scroll it yourself.
//
// Mounted on the element that wraps the video, the sidebar and the source controls:
//
//   <div id="study" phx-hook="StudySidebar" data-video="study-video"> … </div>
//
// Subtitles arrive either from the server (`study:subtitles`, already WebVTT) or from
// the demo button. No libraries: the video is a plain <video>, the list is plain DOM.
import {parseVtt, activeIndex, liveIndexes, formatTime} from "./cues.js"

// After you scroll or click in the list it stops following the video, then picks the
// current line back up on its own once you've been idle this long.
const FOLLOW_RESUME_MS = 5000

export const StudySidebar = {
  mounted() {
    this.video = document.getElementById(this.el.dataset.video)
    this.list = this.el.querySelector("[data-role=list]")
    this.title = this.el.querySelector("[data-role=title]")
    this.count = this.el.querySelector("[data-role=count]")
    this.empty = this.el.querySelector("[data-role=empty]")
    this.pill = this.el.querySelector("[data-role=resume]")

    this.cues = []
    this.rows = []
    this.idx = -1
    this.live = []
    this.follow = true
    this.programmatic = false
    this.objectUrl = null

    this.bindVideo()
    this.bindList()
    this.bindSource()

    this.handleEvent("study:subtitles", ({vtt, name}) => this.setCues(vtt, name))
  },

  destroyed() {
    cancelAnimationFrame(this.raf)
    clearTimeout(this.resumeTimer)
    clearTimeout(this.progTimer)
    if (this.objectUrl) URL.revokeObjectURL(this.objectUrl)
  },

  // ── the video ──────────────────────────────────────────────────────

  bindVideo() {
    const v = this.video
    const tick = () => this.tick()

    // While playing, every frame: a line should light up when it starts, not up to a
    // quarter-second later (timeupdate's rate). When paused or seeking, the events do it.
    const loop = () => {
      this.tick()
      this.raf = requestAnimationFrame(loop)
    }
    v.addEventListener("play", () => {
      cancelAnimationFrame(this.raf)
      loop()
    })
    for (const ev of ["pause", "ended"]) v.addEventListener(ev, () => { cancelAnimationFrame(this.raf); tick() })
    for (const ev of ["seeked", "timeupdate", "loadedmetadata"]) v.addEventListener(ev, tick)
  },

  tick() {
    if (!this.cues.length) return
    const t = this.video.currentTime
    const idx = activeIndex(this.cues, t)
    const live = liveIndexes(this.cues, idx, t)

    if (idx !== this.idx) this.setIndex(idx)
    this.setLive(live)
  },

  // ── the list ───────────────────────────────────────────────────────

  setCues(vtt, name) {
    this.cues = parseVtt(vtt)
    this.idx = -1
    this.live = []
    this.list.textContent = ""
    this.rows = []

    this.title.textContent = name || "Subtitles"
    this.empty.hidden = this.cues.length > 0
    this.empty.textContent = this.cues.length ? "" : "No subtitle lines found in that file."
    this.count.textContent = this.cues.length ? `0 / ${this.cues.length}` : ""

    // One row per cue, built once. Highlighting only ever flips attributes after this.
    const frag = document.createDocumentFragment()
    this.cues.forEach((cue, i) => {
      const row = document.createElement("div")
      row.className = "study-row"
      row.dataset.idx = i
      row.dataset.state = "future"
      row.tabIndex = 0
      row.setAttribute("role", "button")

      const time = document.createElement("span")
      time.className = "study-time"
      time.textContent = formatTime(cue.start)

      const text = document.createElement("span")
      text.className = "study-text"
      text.textContent = cue.text // text, never HTML: a subtitle file is untrusted

      row.append(time, text)
      frag.appendChild(row)
      this.rows.push(row)
    })
    this.list.appendChild(frag)

    this.setFollow(true)
    this.tick()
    if (this.idx >= 0) this.scrollToIndex(this.idx, false)
  },

  // The line you are on changed. Rows before it are "past", it is "current", the rest are
  // "future"; only the rows between the old and new position can have changed state.
  setIndex(idx) {
    const prev = this.idx
    const from = Math.max(0, Math.min(prev, idx))
    const to = Math.min(this.rows.length - 1, Math.max(prev, idx))

    for (let i = from; i <= to; i++) {
      this.rows[i].dataset.state = i < idx ? "past" : i === idx ? "current" : "future"
    }
    this.idx = idx
    this.count.textContent = `${idx + 1} / ${this.cues.length}`

    if (this.follow && idx >= 0) {
      // A line coming up in order glides; a seek jumps, so it doesn't scroll for a second.
      this.scrollToIndex(idx, !this.video.paused && idx === prev + 1)
    }
  },

  // The line(s) being spoken right now are brighter than the one just heard.
  setLive(live) {
    if (live.length === this.live.length && live.every((v, i) => v === this.live[i])) return
    for (const i of this.live) delete this.rows[i].dataset.live
    for (const i of live) this.rows[i].dataset.live = "true"
    this.live = live
  },

  // Centre a row in the list — scrolling the list itself, never the page (scrollIntoView
  // would walk up and shove the video off screen).
  scrollToIndex(i, smooth) {
    const row = this.rows[i]
    if (!row) return
    const top = row.offsetTop - (this.list.clientHeight - row.offsetHeight) / 2

    this.programmatic = true
    this.list.scrollTo({top: Math.max(0, top), behavior: smooth ? "smooth" : "auto"})
    clearTimeout(this.progTimer)
    this.progTimer = setTimeout(() => (this.programmatic = false), smooth ? 700 : 120)
  },

  bindList() {
    // Real intent only — wheel, touch, or grabbing the scrollbar. Scroll events also fire
    // for our own scrolling, so they cannot tell the two apart.
    const userTouch = () => {
      this.setFollow(false)
      clearTimeout(this.resumeTimer)
      this.resumeTimer = setTimeout(() => this.resume(), FOLLOW_RESUME_MS)
    }
    for (const ev of ["wheel", "touchstart", "pointerdown"]) this.list.addEventListener(ev, userTouch, {passive: true})

    // Click (or Enter) a line: play from there, and follow again.
    const seek = (e) => {
      const row = e.target.closest(".study-row")
      if (!row) return
      this.video.currentTime = this.cues[Number(row.dataset.idx)].start
      this.video.play().catch(() => {})
      this.resume()
    }
    this.list.addEventListener("click", seek)
    this.list.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault()
        seek(e)
      }
    })

    this.pill.addEventListener("click", () => this.resume())
  },

  setFollow(on) {
    this.follow = on
    this.pill.hidden = on || this.idx < 0
  },

  resume() {
    clearTimeout(this.resumeTimer)
    this.setFollow(true)
    if (this.idx >= 0) this.scrollToIndex(this.idx, true)
  },

  // ── where the video and subtitles come from ────────────────────────

  bindSource() {
    const $ = (sel) => this.el.querySelector(sel)

    // A file from this computer: played straight from disk, nothing is uploaded.
    $("[data-role=video-file]").addEventListener("change", (e) => {
      const file = e.target.files[0]
      if (file) this.setSource(URL.createObjectURL(file))
    })

    $("[data-role=video-url-form]").addEventListener("submit", (e) => {
      e.preventDefault()
      const url = new FormData(e.target).get("url").trim()
      if (/^(https?:\/\/|\/)/.test(url)) this.setSource(url)
    })

    $("[data-role=demo]").addEventListener("click", async () => {
      this.setSource(URL.createObjectURL(silentWav(75)))
      const vtt = await (await fetch("/study/demo.vtt")).text()
      this.setCues(vtt, "Demo — français")
    })
  },

  setSource(src) {
    if (this.objectUrl) URL.revokeObjectURL(this.objectUrl)
    this.objectUrl = src.startsWith("blob:") ? src : null
    this.video.src = src
    this.video.load()
  },
}

// A silent mono 8-bit WAV of `seconds`, so the demo has a real, seekable media timeline
// to drive the sidebar without shipping a video file.
function silentWav(seconds, rate = 4000) {
  const n = seconds * rate
  const buf = new ArrayBuffer(44 + n)
  const v = new DataView(buf)
  const str = (o, s) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)))

  str(0, "RIFF"); v.setUint32(4, 36 + n, true); str(8, "WAVE")
  str(12, "fmt "); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true)
  v.setUint32(24, rate, true); v.setUint32(28, rate, true); v.setUint16(32, 1, true); v.setUint16(34, 8, true)
  str(36, "data"); v.setUint32(40, n, true)
  new Uint8Array(buf, 44).fill(128) // 8-bit PCM silence is 0x80

  return new Blob([buf], {type: "audio/wav"})
}
