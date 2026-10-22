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

// ── words on the screen ───────────────────────────────────────────────

// Subtitle language codes as ffmpeg and the providers spell them, as the two letters the
// dictionary route takes.
const SHORT = {
  jpn: "ja", ja: "ja", eng: "en", en: "en", fre: "fr", fra: "fr", fr: "fr", spa: "es", es: "es",
  ger: "de", deu: "de", de: "de", ita: "it", it: "it", por: "pt", pt: "pt", rus: "ru", ru: "ru",
  kor: "ko", ko: "ko", chi: "zh", zho: "zh", zh: "zh", dut: "nl", nld: "nl", nl: "nl",
  pol: "pl", pl: "pl", tur: "tr", tr: "tr", swe: "sv", sv: "sv", ara: "ar", ar: "ar",
}
// The languages the dictionary route knows (English is what the cards are written in).
const LOOKUP = new Set(["ja", "fr", "es", "de", "it", "pt", "ru", "ko", "zh", "nl", "pl", "tr", "sv", "ar"])
const shortLang = (code) => SHORT[String(code || "").toLowerCase()] || ""

const segmenterJa = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter("ja", {granularity: "word"}) : null
const WORDS = /[\p{L}\p{M}\p{N}]+(?:['’-][\p{L}\p{M}]+)*|[^\p{L}\p{M}\p{N}]+/gu

// The browser's segmenter cuts a conjugated verb into its pieces (食べ・ま・し・た); a dictionary
// wants 食べました. A word that starts with kanji or katakana takes the hiragana right after it
// (the endings) — up to a few characters, and not past a particle (は が を に の …; で only after
// ん, as in 読んで).
const PARTICLES = new Set(["は", "が", "を", "に", "へ", "と", "も", "の", "や", "か", "ね", "よ", "な", "ぞ", "ぜ", "わ", "さ", "で"])
const HIRAGANA = /^[\p{Script=Hiragana}ー]+$/u

function joinInflections(parts) {
  const out = []
  for (let i = 0; i < parts.length; i++) {
    const cur = {...parts[i]}
    out.push(cur)
    if (!cur.w || HIRAGANA.test(cur.t)) continue

    let tail = 0
    while (i + 1 < parts.length) {
      const next = parts[i + 1]
      if (!next.w || !HIRAGANA.test(next.t)) break
      const particle = PARTICLES.has(next.t[0]) && !(next.t[0] === "で" && cur.t.endsWith("ん"))
      if (particle || tail + next.t.length > 6) break
      cur.t += next.t
      tail += next.t.length
      i++
    }
  }
  return out
}

// A line cut into `{t, w}` pieces: `w` is true for a word you can ask about. Japanese has no
// spaces, so the browser's own segmenter finds the words; everything else splits on letters.
function wordsOf(text, lang) {
  if ((lang === "ja" || lang === "zh") && segmenterJa) {
    const parts = [...segmenterJa.segment(text)].map((x) => ({t: x.segment, w: !!x.isWordLike && /[\p{L}\p{N}]/u.test(x.segment)}))
    return lang === "ja" ? joinInflections(parts) : parts
  }
  return [...text.matchAll(WORDS)].map((m) => ({t: m[0], w: /[\p{L}\p{N}]/u.test(m[0])}))
}

const store = {
  get(key) { try { return localStorage.getItem("roki:study:" + key) } catch { return null } },
  set(key, value) { try { localStorage.setItem("roki:study:" + key, value) } catch {} },
}

export const StudySidebar = {
  mounted() {
    this.video = document.getElementById(this.el.dataset.video)
    this.list = this.el.querySelector("[data-role=list]")
    this.title = this.el.querySelector("[data-role=title]")
    this.count = this.el.querySelector("[data-role=count]")
    this.empty = this.el.querySelector("[data-role=empty]")
    this.pill = this.el.querySelector("[data-role=resume]")
    this.ui = this.el.querySelector("#study-ui")
    this.stage = this.el.querySelector("[data-role=stage]")
    this.overlay = this.el.querySelector("[data-role=overlay]")
    this.tip = this.el.querySelector("[data-role=tip]")
    this.tracksBar = this.el.querySelector("[data-role=tracks]")

    this.lang = ""
    this.trackKey = ""
    this.overlayKey = ""
    this.overlayOn = store.get("overlay") !== "off"
    this.tracks = []
    this.dict = new Map()

    this.cues = []
    this.rows = []
    this.idx = -1
    this.live = []
    this.follow = true
    this.programmatic = false
    this.objectUrl = null

    this.el.study = this // for tests and the console
    this.bindVideo()
    this.bindList()
    this.bindSource()
    this.bindUi()

    this.handleEvent("study:subtitles", ({vtt, name}) => this.setCues(vtt, name))

    this.readPlayer()
  },

  // LiveView only ever changes `data-player` on the root (the video and list are ignored
  // regions), so every update lands here.
  updated() {
    this.readPlayer()
  },

  destroyed() {
    cancelAnimationFrame(this.raf)
    clearTimeout(this.tipTimer)
    clearTimeout(this.resumeTimer)
    clearTimeout(this.progTimer)
    clearInterval(this.seekTimer)
    clearInterval(this.postTimer)
    if (this.hls) this.hls.destroy()
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

    // Progress goes back to the server only when the page asked for it, and never before the
    // resume seek has happened (a playhead at 0 would overwrite where you were).
    if (this.el.dataset.progress === "true") {
      this.postTimer = setInterval(() => !v.paused && this.postProgress(), 5000)
      v.addEventListener("pause", () => this.postProgress(true))
      v.addEventListener("ended", () => {
        this.postProgress(true)
        this.pushEvent("ended", {})
      })
    }
  },

  postProgress(paused = false) {
    const v = this.video
    if (!this.ready || !(v.currentTime > 0)) return
    this.pushEvent("progress", {
      position: Math.floor(v.currentTime),
      duration: Number.isFinite(v.duration) ? Math.floor(v.duration) : 0,
      paused,
    })
  },

  tick() {
    if (!this.cues.length) return
    const t = this.video.currentTime
    const idx = activeIndex(this.cues, t)
    const live = liveIndexes(this.cues, idx, t)

    if (idx !== this.idx) this.setIndex(idx)
    this.setLive(live)
    this.renderOverlay(live)
  },

  // ── the subtitles over the picture ─────────────────────────────────

  // The line(s) being spoken, each word its own element so it can be asked about. Rebuilt only
  // when the lines (or the track) change, never every frame.
  renderOverlay(live) {
    const key = this.overlayOn ? `${this.trackKey}|${live.join(",")}` : "off"
    if (key === this.overlayKey) return
    this.overlayKey = key
    this.hideTip()
    this.overlay.textContent = ""
    if (!this.overlayOn) return

    const lookup = LOOKUP.has(this.lang)
    for (const i of live) {
      const line = document.createElement("div")
      line.className = "study-line"
      for (const part of wordsOf(this.cues[i].text, this.lang)) {
        if (lookup && part.w) {
          const w = document.createElement("span")
          w.className = "study-word"
          w.textContent = part.t // text, never HTML: a subtitle file is untrusted
          line.appendChild(w)
        } else {
          line.appendChild(document.createTextNode(part.t))
        }
      }
      this.overlay.appendChild(line)
    }
  },

  // Hover (mouse) or tap (touch) a word: a card with what it means. A click also stops the
  // video so there is time to read it.
  bindWords() {
    const wordOf = (e) => e.target.closest && e.target.closest(".study-word")

    this.overlay.addEventListener("pointerover", (e) => {
      const w = wordOf(e)
      if (!w || e.pointerType !== "mouse") return
      clearTimeout(this.tipTimer)
      this.tipTimer = setTimeout(() => this.showTip(w), 120)
    })
    this.overlay.addEventListener("pointerout", (e) => {
      if (!wordOf(e) || e.pointerType !== "mouse" || this.pinned) return
      clearTimeout(this.tipTimer)
      this.tipTimer = setTimeout(() => this.hideTip(), 150)
    })
    this.overlay.addEventListener("click", (e) => {
      const w = wordOf(e)
      if (!w) return
      e.stopPropagation()
      this.video.pause()
      this.pinned = true
      this.showTip(w)
    })
    // Anywhere else: let it go.
    this.stage.addEventListener("click", (e) => { if (!wordOf(e)) this.hideTip() })
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") this.hideTip() })
  },

  async showTip(word) {
    const text = word.textContent
    const lang = this.lang
    this.tipFor = word
    for (const el of this.overlay.querySelectorAll("[data-on]")) delete el.dataset.on
    word.dataset.on = "true"

    this.fillTip(word, text, null)
    const result = await this.define(lang, text)
    if (this.tipFor === word) this.fillTip(word, text, result)
  },

  async define(lang, word) {
    const key = `${lang}:${word}`
    if (this.dict.has(key)) return this.dict.get(key)
    let result = {entries: []}
    try {
      const res = await fetch(`/dict/${lang}?q=${encodeURIComponent(word)}`, {credentials: "same-origin"})
      if (res.ok) result = await res.json()
      else if (res.status === 429) result = {entries: [], note: "Too many lookups; wait a moment."}
      else result = {entries: [], note: "No dictionary right now."}
    } catch {
      result = {entries: [], note: "No dictionary right now."}
    }
    if (!result.note) this.dict.set(key, result)
    return result
  },

  // result: null while it is loading.
  fillTip(word, text, result) {
    const tip = this.tip
    tip.textContent = ""

    const add = (parent, tag, cls, txt) => {
      const el = document.createElement(tag)
      if (cls) el.className = cls
      if (txt != null) el.textContent = txt
      parent.appendChild(el)
      return el
    }

    if (!result) {
      add(add(tip, "div"), "span", "tip-word", text)
      add(tip, "div", "tip-note", "…")
    } else if (!result.entries.length) {
      add(tip, "div", "tip-word", text)
      add(tip, "div", "tip-note", result.note || "Not in the dictionary.")
    } else {
      for (const e of result.entries.slice(0, 3)) {
        const box = add(tip, "div", "tip-entry")
        const head = add(box, "div")
        add(head, "span", "tip-word", e.word)
        if (e.reading) add(head, "span", "tip-reading", e.reading)
        if (e.pos && e.pos.length) add(box, "div", "tip-pos", e.pos.join(" · "))
        const list = add(box, "ol")
        for (const m of (e.meanings || []).slice(0, 3)) add(list, "li", null, m)
      }
    }
    tip.hidden = false
    this.placeTip(word)
  },

  // Above the word when there is room, below it when not; kept inside the picture.
  placeTip(word) {
    const stage = this.stage.getBoundingClientRect()
    const w = word.getBoundingClientRect()
    const tip = this.tip
    // A small picture (a phone) has room for fewer meanings: drop the last entries until it fits.
    while (tip.querySelectorAll(".tip-entry").length > 1 && tip.offsetHeight > stage.height * 0.62) {
      tip.querySelector(".tip-entry:last-child").remove()
    }
    const width = tip.offsetWidth
    const height = tip.offsetHeight
    let left = w.left - stage.left + w.width / 2 - width / 2
    left = Math.max(6, Math.min(left, stage.width - width - 6))
    // Above the word if it fits there, else below it, else wherever it fits in the picture.
    let top = w.top - stage.top - height - 8
    if (top < 6) {
      top = w.bottom - stage.top + 8
      if (top + height > stage.height - 6) top = Math.max(6, stage.height - height - 6)
    }
    tip.style.left = `${left}px`
    tip.style.top = `${top}px`
  },

  hideTip() {
    this.pinned = false
    this.tipFor = null
    if (this.tip) this.tip.hidden = true
    if (this.overlay) for (const el of this.overlay.querySelectorAll("[data-on]")) delete el.dataset.on
  },

  // ── theater mode, fullscreen, the box ──────────────────────────────

  bindUi() {
    const $ = (sel) => this.el.querySelector(sel)
    this.bindWords()

    const theater = $("[data-role=theater]")
    const setTheater = (on) => {
      this.ui.dataset.theater = on ? "true" : "false"
      theater.setAttribute("aria-pressed", String(on))
      theater.classList.toggle("btn-primary", on)
      store.set("theater", on ? "1" : "0")
      // The picture changed size under a card that may be open.
      if (this.tipFor) this.placeTip(this.tipFor)
    }
    theater.addEventListener("click", () => setTheater(this.ui.dataset.theater !== "true"))
    setTheater(store.get("theater") === "1")

    $("[data-role=fullscreen]").addEventListener("click", () => {
      if (document.fullscreenElement) document.exitFullscreen()
      else if (this.stage.requestFullscreen) this.stage.requestFullscreen().catch(() => {})
      else if (this.video.webkitEnterFullscreen) this.video.webkitEnterFullscreen()
    })

    // The box: open, smaller, or just its title bar (and then the chevron opens it again).
    const collapse = $("[data-role=collapse]")
    const compact = $("[data-role=compact]")
    const setPanel = (state) => {
      this.ui.dataset.panel = state
      collapse.setAttribute("aria-expanded", String(state !== "closed"))
      compact.classList.toggle("btn-active", state === "compact")
      store.set("panel", state)
      if (state !== "closed") requestAnimationFrame(() => this.idx >= 0 && this.scrollToIndex(this.idx, false))
    }
    collapse.addEventListener("click", () => setPanel(this.ui.dataset.panel === "closed" ? "open" : "closed"))
    compact.addEventListener("click", () => setPanel(this.ui.dataset.panel === "compact" ? "open" : "compact"))
    const saved = store.get("panel")
    setPanel(["open", "compact", "closed"].includes(saved) ? saved : "open")
  },

  // ── the list ───────────────────────────────────────────────────────

  setCues(vtt, name, track) {
    this.cues = parseVtt(vtt)
    if (track) {
      this.lang = shortLang(track.lang)
      this.trackKey = track.url
    }
    this.overlayKey = ""
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

    // The title page has none of these controls; the /study page has all of them.
    if (!$("[data-role=demo]")) return

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

  // ── a real release, from the title page ────────────────────────────

  readPlayer() {
    const raw = this.el.dataset.player
    if (!raw) return

    let p
    try { p = JSON.parse(raw) } catch { return }

    if (p.url !== this.playerUrl) {
      this.playerUrl = p.url
      this.startMedia(p)
    }
    const key = JSON.stringify(p.tracks)
    if (key !== this.tracksKey) {
      this.tracksKey = key
      this.setTracks(p)
    }
  },

  async startMedia(p) {
    const v = this.video
    this.ready = !(p.resume > 0)
    clearInterval(this.seekTimer)
    if (this.hls) { this.hls.destroy(); this.hls = null }
    this.cues = []
    this.audioWrap().hidden = true

    if (p.hls && !v.canPlayType("application/vnd.apple.mpegurl")) {
      const Hls = await loadHls()
      if (this.playerUrl !== p.url) return // another source was chosen while it loaded
      if (!Hls || !Hls.isSupported()) { this.title.textContent = "This browser can't play HLS."; return }

      const hls = (this.hls = new Hls({
        maxBufferLength: 60,
        // A growing playlist is still a film, not a broadcast: a finite duration, a seek bar,
        // and (when coming back to it) a start where you left off instead of the live edge.
        liveDurationInfinity: false,
        startPosition: p.resume > 0 ? p.resume : -1,
      }))
      hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, () => this.setAudioTracks(hls))
      hls.loadSource(p.url)
      hls.attachMedia(v)
    } else {
      v.src = p.url
      v.load()
    }

    if (p.resume > 0) this.seekWhenReachable(p.resume)
    v.play().catch(() => {}) // may be refused without a gesture; the controls are right there
  },

  // The remux is written while you watch, so a position far in may not exist yet. Wait for
  // it, up to two minutes, then start from the beginning rather than never.
  seekWhenReachable(t) {
    const v = this.video
    let tries = 0
    this.seekTimer = setInterval(() => {
      const r = v.seekable
      const reach = r.length ? r.end(r.length - 1) : 0
      if (reach >= t - 1) {
        v.currentTime = t
        this.ready = true
        clearInterval(this.seekTimer)
      } else if (++tries > 240) {
        this.ready = true
        clearInterval(this.seekTimer)
      }
    }, 500)
  },

  audioWrap() { return this.el.querySelector("[data-role=audio-wrap]") },

  setAudioTracks(hls) {
    const wrap = this.audioWrap()
    const sel = wrap.querySelector("select")
    sel.textContent = ""
    hls.audioTracks.forEach((t, i) => {
      const o = document.createElement("option")
      o.value = i
      o.textContent = t.name || t.lang || `Track ${i + 1}`
      sel.appendChild(o)
    })
    sel.value = hls.audioTrack
    sel.onchange = () => (hls.audioTrack = Number(sel.value))
    wrap.hidden = hls.audioTracks.length < 2
  },

  // Subtitle tracks of the release (and any fetched later), as buttons under the player: one
  // each, and Off for the overlay. The one in the user's language is loaded first.
  setTracks(p) {
    const tracks = p.tracks || []
    const current = this.trackUrl
    this.tracks = tracks

    if (!tracks.length) {
      this.renderChips(-1)
      if (!this.cues.length) {
        this.empty.hidden = false
        this.empty.textContent = "No subtitles came with this release."
      }
      return
    }
    const want = tracks.findIndex((t) => p.prefer && shortLang(t.lang) === p.prefer)
    const kept = tracks.findIndex((t) => t.url === current)
    // Keep what is showing unless something in the preferred language has just arrived.
    const pick = want >= 0 && (kept < 0 || shortLang(tracks[kept].lang) !== p.prefer) ? want : kept >= 0 ? kept : Math.max(want, 0)
    this.renderChips(pick)
    if (tracks[pick].url !== current) this.loadTrack(tracks[pick])
  },

  renderChips(active) {
    const bar = this.tracksBar
    bar.textContent = ""
    if (!this.tracks.length) return

    const chip = (label, on, click) => {
      const b = document.createElement("button")
      b.type = "button"
      b.className = "btn btn-sm " + (on ? "btn-primary" : "")
      b.textContent = label
      b.setAttribute("aria-pressed", String(on))
      b.addEventListener("click", click)
      bar.appendChild(b)
    }

    const seen = {}
    this.tracks.forEach((t, i) => {
      seen[t.label] = (seen[t.label] || 0) + 1
      const label = seen[t.label] > 1 ? `${t.label} ${seen[t.label]}` : t.label
      chip(label, this.overlayOn && i === active, () => this.pickTrack(i))
    })
    chip("Off", !this.overlayOn, () => this.pickTrack(-1))
    this.activeTrack = active
  },

  pickTrack(i) {
    this.overlayOn = i >= 0
    store.set("overlay", this.overlayOn ? "on" : "off")
    if (i >= 0 && this.tracks[i].url !== this.trackUrl) this.loadTrack(this.tracks[i])
    this.overlayKey = ""
    this.renderChips(i >= 0 ? i : this.activeTrack)
    this.tick()
    if (!this.overlayOn) this.renderOverlay([])
  },

  // A release's tracks are written by ffmpeg while the player already runs: the file may not
  // exist yet (404) and then grows as it reads on. So it is fetched again every few seconds
  // until it stops getting longer.
  async loadTrack(track) {
    if (!track) return
    this.trackUrl = track.url
    let seen = -1
    let still = 0

    for (let tries = 0; tries < 75 && this.trackUrl === track.url; tries++) {
      try {
        const res = await fetch(track.url, {credentials: "same-origin", cache: "no-store"})

        if (res.ok) {
          const text = await res.text()
          if (this.trackUrl !== track.url) return
          const n = parseVtt(text).length
          if (n === 0) {
            // Created but nothing written yet: ffmpeg has not reached the first line.
            if (!this.cues.length) {
              this.empty.hidden = false
              this.empty.textContent = "Reading the subtitles out of the release…"
            }
          } else if (n > seen) {
            seen = n
            still = 0
            this.setCues(text, track.label, track)
          } else if (++still >= 3) return
        } else if (res.status === 404) {
          if (!this.cues.length) {
            this.empty.hidden = false
            this.empty.textContent = "Reading the subtitles out of the release…"
          }
        } else {
          this.title.textContent = "Couldn't load that subtitle track."
          return
        }
      } catch {
        this.title.textContent = "Couldn't load that subtitle track."
      }
      await new Promise((resolve) => setTimeout(resolve, 4000))
    }
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

// hls.js is a self-hosted file (`/vendor/hls.min.js`), loaded the first time something needs
// it; browsers with native HLS (Safari) never download it.
let hlsPromise
function loadHls() {
  if (window.Hls) return Promise.resolve(window.Hls)
  hlsPromise ||= new Promise((resolve) => {
    const el = document.createElement("script")
    el.src = "/vendor/hls.min.js"
    el.onload = () => resolve(window.Hls)
    el.onerror = () => { hlsPromise = null; resolve(null) }
    document.head.appendChild(el)
  })
  return hlsPromise
}
