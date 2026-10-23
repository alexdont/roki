// The study player: subtitles over the picture and in a list beside it, in one or two
// languages, with a dictionary under every word. Ported from the idea of debrid_theatre.
//
// Mounted on the element that wraps everything (`#study`, see StudyComponents):
//
//   - the video, with the line being spoken drawn over it; under it, the translation
//   - a card for any word you hover (Japanese is cut into words with Kuromoji and looked up by
//     its dictionary form: 食べ → 食べる), the video pausing while you read it
//   - every line in a list: the words, the translation, and a ▶ that plays from there
//   - tracks to pick under the video — one to study, one as the translation —, a sync offset,
//     caption size, "pause after each line" with a replay button, theater mode
//
// No framework: the video is a plain <video>, the rest is plain DOM.
import {parseVtt, activeIndex, liveIndexes, formatTime} from "./cues.js"

// After you scroll the list it stops following the video, then picks the current line back up
// on its own once you've been idle this long.
const FOLLOW_RESUME_MS = 5000
// How long a word must be hovered before the video stops and the card opens (a sweep of the
// mouse across the line should not).
const DWELL_MS = 300

// ── languages and words ───────────────────────────────────────────────

// Subtitle language codes as ffmpeg and the providers spell them → the two letters the
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

const store = {
  get(key) { try { return localStorage.getItem("roki:study:" + key) } catch { return null } },
  set(key, value) { try { localStorage.setItem("roki:study:" + key, value) } catch {} },
}

// Kuromoji (a dictionary-based Japanese tokenizer: words, base forms, readings) is a 300 KB script
// and 17 MB of dictionary, both fetched the first time a Japanese track is shown and cached by
// the browser after that. Until it is ready the browser's own segmenter does the cutting.
let tokenizer = null
let kuromojiPromise = null
function loadKuromoji() {
  kuromojiPromise ||= new Promise((resolve) => {
    const build = () =>
      window.kuromoji.builder({dicPath: "/kuromoji/dict/"}).build((err, tok) => {
        if (err) { console.error("kuromoji", err); resolve(null) }
        else { tokenizer = tok; resolve(tok) }
      })
    if (window.kuromoji) return build()
    const el = document.createElement("script")
    el.src = "/vendor/kuromoji.js"
    el.onload = build
    el.onerror = () => resolve(null)
    document.head.appendChild(el)
  })
  return kuromojiPromise
}

const segmenterJa = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter("ja", {granularity: "word"}) : null
const WORDS = /[\p{L}\p{M}\p{N}]+(?:['’-][\p{L}\p{M}]+)*|[^\p{L}\p{M}\p{N}]+/gu
const ISWORD = /[\p{L}\p{N}]/u

// The segmenter alone cuts a conjugated verb into pieces (食べ・ま・し・た); until Kuromoji is
// ready, a word that starts with kanji or katakana takes the hiragana after it, but not past a
// particle (で only after ん, as in 読んで).
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

// A line cut into `{t, w, lemma}` pieces: `w` is true for a word you can ask about, `lemma` is
// the form to look up when it is not the word itself.
function tokensOf(text, lang) {
  if (lang === "ja" && tokenizer) {
    return tokenizer.tokenize(text).map((k) => ({
      t: k.surface_form,
      w: k.pos !== "記号" && ISWORD.test(k.surface_form),
      lemma: k.basic_form && k.basic_form !== "*" && k.basic_form !== k.surface_form ? k.basic_form : null,
    }))
  }
  if ((lang === "ja" || lang === "zh") && segmenterJa) {
    const parts = [...segmenterJa.segment(text)].map((x) => ({t: x.segment, w: !!x.isWordLike && ISWORD.test(x.segment)}))
    return lang === "ja" ? joinInflections(parts) : parts
  }
  return [...text.matchAll(WORDS)].map((m) => ({t: m[0], w: ISWORD.test(m[0])}))
}

// Put a line into `el` as text and, for a language with a dictionary, one hoverable span per
// word. Always text, never HTML: a subtitle file is untrusted.
function fillLine(el, text, lang) {
  el.textContent = ""
  if (!LOOKUP.has(lang)) { el.textContent = text; return }
  for (const part of tokensOf(text, lang)) {
    if (part.w) {
      const w = document.createElement("span")
      w.className = "study-word"
      w.textContent = part.t
      if (part.lemma) w.dataset.lemma = part.lemma
      el.appendChild(w)
    } else {
      el.appendChild(document.createTextNode(part.t))
    }
  }
}

export const StudySidebar = {
  isKuromojiReady() { return !!tokenizer },

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
    this.subsList = this.el.querySelector("[data-role=subs-list]")
    this.subsLabel = this.el.querySelector("[data-role=subs-label]")
    this.backdrop = this.el.querySelector("[data-role=backdrop]")
    this.wide = window.matchMedia("(min-width: 1024px)")

    // The card for a word: its own element, in the page (or in the stage while it is fullscreen).
    this.tip = document.createElement("div")
    this.tip.className = "study-tip"
    this.tip.hidden = true
    this.ui.appendChild(this.tip)

    // Two tracks: `p` is the one being studied (words, list), `s` its translation.
    // Any number of tracks can be on at once, in the order you like. `p` is the first: the one
    // studied (words, the list). `extras` are the rest, shown under it as translations. `want` is
    // the track a layer is for, `url` the one whose lines it has loaded; `cache` keeps what was
    // downloaded so moving a track between roles costs nothing.
    this.p = {cues: [], rows: [], idx: -1, live: [], lang: "", url: null, label: "", want: null}
    this.extras = []
    this.cache = new Map()
    this.userChose = false
    this.tracks = []
    this.follow = true
    this.programmatic = false
    this.objectUrl = null
    this.offset = 0
    this.overlayKey = ""
    this.dict = new Map()
    this.pausedAt = -1
    this.watching = -1
    this.study = store.get("study") === "1"
    this.peek = store.get("peek") === "1"
    this.scale = Math.min(3, Math.max(0.5, parseFloat(store.get("scale")) || 1))

    this.el.study = this // for tests and the console

    this.bindVideo()
    this.bindList()
    this.bindSource()
    this.bindUi()

    this.handleEvent("study:subtitles", ({vtt, name}) => this.setPrimary(vtt, name, {lang: "", url: "upload"}))

    this.readPlayer()
  },

  // LiveView only ever changes `data-player` on the root (the video and the rest are ignored
  // regions), so every update lands here.
  updated() {
    this.readPlayer()
  },

  destroyed() {
    cancelAnimationFrame(this.raf)
    clearTimeout(this.dwellTimer)
    clearTimeout(this.leaveTimer)
    clearTimeout(this.resumeTimer)
    clearTimeout(this.progTimer)
    clearTimeout(this.seekWait)
    clearInterval(this.seekTimer)
    clearInterval(this.postTimer)
    if (this.tip) this.tip.remove()
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

  // The time the subtitles are on: the video's, minus the sync offset.
  now() { return this.video.currentTime - this.offset },

  tick() {
    const p = this.p
    if (!p.cues.length && !this.extras.some((e) => e.cues.length)) return
    const t = this.now()
    const idx = activeIndex(p.cues, t)
    let live = liveIndexes(p.cues, idx, t)

    if (this.study) live = this.studyStep(t, live)

    if (p.cues.length) {
      if (idx !== p.idx) this.setIndex(idx)
      this.setLive(live)
    }
    this.renderOverlay(live, t)
  },

  // "Pause after each line": the line being watched is remembered; at its end the video stops
  // on it (and the line stays on screen to reread) until you press play. A line you just
  // resumed from is not paused on again.
  studyStep(t, live) {
    const cues = this.p.cues
    const v = this.video
    const cur = live.length ? live[live.length - 1] : -1
    if (cur >= 0 && cur !== this.pausedAt) this.watching = cur

    if (this.pausedAt >= 0 && t > cues[this.pausedAt].end + 0.4) this.pausedAt = -1

    if (this.watching >= 0 && !v.paused && t >= cues[this.watching].end - 0.04) {
      this.pausedAt = this.watching
      this.watching = -1
      v.pause()
    }
    return this.pausedAt >= 0 && v.paused && !live.includes(this.pausedAt) ? [this.pausedAt] : live
  },

  replay() {
    const cues = this.p.cues
    const i = this.pausedAt >= 0 ? this.pausedAt : this.p.idx
    if (i < 0 || !cues[i]) return
    this.pausedAt = -1
    this.watching = -1
    this.video.currentTime = Math.max(0, cues[i].start + this.offset)
    this.video.play().catch(() => {})
  },

  // ── the subtitles over the picture ─────────────────────────────────

  // The line(s) being spoken, each word its own element, and the translation under them. Rebuilt
  // only when the lines (or the tracks) change, never every frame.
  renderOverlay(live, t) {
    const extraLive = this.extras.map((e) => {
      const i = e.cues.length ? activeIndex(e.cues, t) : -1
      return i >= 0 ? liveIndexes(e.cues, i, t) : []
    })
    const key = this.p.url
      ? `${this.p.url}|${this.extras.map((e) => e.url).join(",")}|${tokenizer ? 1 : 0}|${live.join(",")}|${extraLive.map((l) => l.join(",")).join(";")}`
      : "off"
    if (key === this.overlayKey) return
    this.overlayKey = key
    if (!this.hovering) this.hideTip()
    this.overlay.textContent = ""
    if (!this.p.url) return

    for (const i of live) {
      const line = document.createElement("div")
      line.className = "study-line"
      line.dataset.lang = this.p.lang
      fillLine(line, this.p.cues[i].text, this.p.lang)
      this.overlay.appendChild(line)
    }
    this.extras.forEach((e, k) => {
      if (!extraLive[k].length) return
      const trans = document.createElement("div")
      trans.className = "study-trans study-line"
      trans.dataset.lang = e.lang
      fillLine(trans, extraLive[k].map((i) => e.cues[i].text).join(" "), e.lang)
      this.overlay.appendChild(trans)
    })
  },

  // ── the card for a word ────────────────────────────────────────────

  // Hover a word (mouse) for a moment: the video stops and a card says what it means; move off
  // and it carries on if it was playing. A tap or a click keeps the card and the pause.
  bindWords() {
    const wordOf = (e) => e.target.closest && e.target.closest(".study-word")

    this.el.addEventListener("mouseover", (e) => {
      const w = wordOf(e)
      if (w) this.wordEnter(w)
    })
    this.el.addEventListener("mouseout", (e) => {
      if (wordOf(e)) this.wordLeave()
    })
    this.el.addEventListener("click", (e) => {
      const w = wordOf(e)
      if (w) {
        this.pinned = true
        if (!this.video.paused) this.video.pause()
        this.hovering = true
        this.wasPlaying = false
        this.showTip(w)
      } else if (!e.target.closest(".study-tip")) {
        this.dismissTip()
      }
    })
    this.tip.addEventListener("mouseenter", () => clearTimeout(this.leaveTimer))
    this.tip.addEventListener("mouseleave", () => this.wordLeave())
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") this.dismissTip() })
  },

  wordEnter(w) {
    clearTimeout(this.leaveTimer)
    if (this.currentWord === w) return
    clearTimeout(this.dwellTimer)
    this.currentWord = w
    if (this.hovering) {
      this.showTip(w) // already reading: the next word at once
    } else {
      this.dwellTimer = setTimeout(() => {
        if (this.currentWord !== w) return
        this.wasPlaying = !this.video.paused
        this.video.pause()
        this.hovering = true
        this.showTip(w)
      }, DWELL_MS)
    }
  },

  wordLeave() {
    clearTimeout(this.dwellTimer)
    if (this.pinned) return
    this.leaveTimer = setTimeout(() => this.dismissTip(), 250)
  },

  // Close the card; if the video was only stopped for the card, let it go on.
  dismissTip() {
    clearTimeout(this.dwellTimer)
    clearTimeout(this.leaveTimer)
    this.hideTip()
    if (this.hovering && this.wasPlaying) this.video.play().catch(() => {})
    this.hovering = false
    this.pinned = false
    this.wasPlaying = false
    this.currentWord = null
  },

  async showTip(word) {
    const text = word.dataset.lemma || word.textContent
    this.tipFor = word
    for (const el of this.el.querySelectorAll("[data-on]")) delete el.dataset.on
    word.dataset.on = "true"

    this.fillTip(word, text, null)
    const lang = this.langOf(word)
    const result = await this.define(lang, text)
    if (this.tipFor === word) this.fillTip(word, text, result)
  },

  // Which track's language a word on screen belongs to: the line (or list row text) it is in.
  langOf(word) {
    const holder = word.closest("[data-lang]")
    return (holder && holder.dataset.lang) || this.p.lang
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
      add(tip, "div", "tip-word", text)
      add(tip, "div", "tip-note", "…")
    } else if (!result.entries.length) {
      add(tip, "div", "tip-word", text)
      add(tip, "div", "tip-note", result.note || "Not in the dictionary.")
    } else {
      for (const e of result.entries.slice(0, 3)) {
        const box = add(tip, "div", "tip-entry")
        const head = add(box, "div")
        add(head, "span", "tip-word", e.word)
        if (e.reading) add(head, "span", "tip-reading", `【${e.reading}】`)
        if (e.jlpt) add(head, "span", "tip-jlpt", e.jlpt)
        if (e.pos && e.pos.length) add(box, "div", "tip-pos", e.pos.join(" · "))
        const list = add(box, "ol")
        for (const m of (e.meanings || []).slice(0, 3)) add(list, "li", null, m)
      }
    }
    tip.hidden = false
    this.placeTip(word)
  },

  // Beside the word where there is room (below it, else above), kept inside what contains it:
  // the picture when fullscreen, the window otherwise.
  placeTip(word) {
    const tip = this.tip
    const inStage = tip.parentElement === this.stage
    const box = inStage
      ? this.stage.getBoundingClientRect()
      : {left: 0, top: 0, width: window.innerWidth, height: window.innerHeight}
    const w = word.getBoundingClientRect()

    // A small picture (a phone) has room for fewer meanings: drop the last entries until it fits.
    while (tip.querySelectorAll(".tip-entry").length > 1 && tip.offsetHeight > box.height * 0.6) {
      tip.querySelector(".tip-entry:last-child").remove()
    }
    const width = tip.offsetWidth
    const height = tip.offsetHeight

    let left = w.left - box.left + w.width / 2 - width / 2
    left = Math.max(6, Math.min(left, box.width - width - 6))
    let top = w.bottom - box.top + 8
    if (top + height > box.height - 6) {
      top = w.top - box.top - height - 8
      if (top < 6) top = Math.max(6, box.height - height - 6)
    }
    tip.style.left = `${left}px`
    tip.style.top = `${top}px`
  },

  hideTip() {
    this.tipFor = null
    if (this.tip) this.tip.hidden = true
    for (const el of this.el.querySelectorAll("[data-on]")) delete el.dataset.on
  },

  // ── theater mode, fullscreen, the box, the controls ────────────────

  bindUi() {
    const $ = (sel) => this.el.querySelector(sel)
    this.bindWords()

    // ── theater and fullscreen
    const theater = $("[data-role=theater]")
    const setTheater = (on) => {
      this.ui.dataset.theater = on ? "true" : "false"
      theater.setAttribute("aria-pressed", String(on))
      theater.classList.toggle("btn-primary", on)
      store.set("theater", on ? "1" : "0")
      if (this.tipFor) this.placeTip(this.tipFor)
    }
    theater.addEventListener("click", () => setTheater(this.ui.dataset.theater !== "true"))
    setTheater(store.get("theater") === "1")

    // Fullscreen is the picture with its subtitles (the card goes in with it), not the bare video.
    $("[data-role=fullscreen]").addEventListener("click", () => {
      if (document.fullscreenElement) document.exitFullscreen()
      else if (this.stage.requestFullscreen) this.stage.requestFullscreen().catch(() => {})
      else if (this.video.webkitEnterFullscreen) this.video.webkitEnterFullscreen()
    })
    document.addEventListener("fullscreenchange", () => {
      const full = document.fullscreenElement === this.stage
      ;(full ? this.stage : this.ui).appendChild(this.tip)
      this.hideTip()
    })

    // ── the list of lines: beside the picture on a wide screen (open, smaller, or gone), a sheet
    // that slides up on a narrow one.
    const lines = $("[data-role=lines-btn]")
    const collapse = $("[data-role=collapse]")
    const compact = $("[data-role=compact]")
    const showList = () => this.p.idx >= 0 && requestAnimationFrame(() => this.scrollToIndex(this.p.idx, false))
    const reflect = () => {
      const open = this.wide.matches ? this.ui.dataset.panel !== "closed" : this.ui.dataset.sheet === "open"
      lines.setAttribute("aria-pressed", String(open))
      lines.classList.toggle("btn-primary", open)
      collapse.setAttribute("aria-expanded", String(open))
      this.syncBackdrop()
    }
    this.setPanel = (state) => {
      this.ui.dataset.panel = state
      compact.classList.toggle("btn-active", state === "compact")
      store.set("panel", state)
      if (state !== "closed") showList()
      reflect()
    }
    this.setSheet = (open) => {
      this.ui.dataset.sheet = open ? "open" : "closed"
      if (open) { this.closePops(); showList() }
      reflect()
    }
    const toggleList = () => {
      if (this.wide.matches) this.setPanel(this.ui.dataset.panel === "closed" ? "open" : "closed")
      else this.setSheet(this.ui.dataset.sheet !== "open")
    }
    lines.addEventListener("click", toggleList)
    collapse.addEventListener("click", toggleList)
    compact.addEventListener("click", () => this.setPanel(this.ui.dataset.panel === "compact" ? "open" : "compact"))
    const savedPanel = store.get("panel")
    this.setPanel(["open", "compact", "closed"].includes(savedPanel) ? savedPanel : "open")
    this.wide.addEventListener("change", reflect)

    // ── the two menus
    this.pops = {
      subs: {btn: $("[data-role=subs-btn]"), menu: $("[data-role=subs-menu]")},
      settings: {btn: $("[data-role=settings-btn]"), menu: $("[data-role=settings-menu]")},
    }
    for (const [name, pop] of Object.entries(this.pops)) {
      pop.btn.addEventListener("click", (e) => {
        e.stopPropagation()
        const open = pop.menu.hidden
        this.closePops()
        if (open) this.openPop(name)
      })
    }
    for (const close of this.el.querySelectorAll("[data-role=pop-close]")) close.addEventListener("click", () => this.closePops())
    this.backdrop.addEventListener("click", () => { this.closePops(); if (!this.wide.matches) this.setSheet(false) })
    // Outside a menu closes it. The path is read at the click: a row that re-drew the menu is gone
    // from the page by the time this runs, and would look like an outside click.
    document.addEventListener("click", (e) => {
      const inside = e.composedPath().some((n) => n.classList && (n.classList.contains("study-pop") || n.matches("[data-role=subs-btn], [data-role=settings-btn]")))
      if (!inside) this.closePops()
    })
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { this.closePops(); if (!this.wide.matches) this.setSheet(false) }
    })

    // ── settings: timing (a file made for another cut), text size, study mode, peek
    const offsetLabel = $("[data-role=offset]")
    this.setOffset = (value) => {
      this.offset = Math.round(value * 100) / 100
      offsetLabel.textContent = `${this.offset > 0 ? "+" : ""}${this.offset}s`
      store.set("offset:" + (this.mediaKey || ""), String(this.offset))
      this.overlayKey = ""
      this.tick()
    }
    $("[data-role=later]").addEventListener("click", () => this.setOffset(this.offset + 0.25))
    $("[data-role=earlier]").addEventListener("click", () => this.setOffset(this.offset - 0.25))
    offsetLabel.addEventListener("click", () => this.setOffset(0))

    const scaleLabel = $("[data-role=scale]")
    const setScale = (value) => {
      this.scale = Math.min(3, Math.max(0.5, Math.round(value * 100) / 100))
      this.ui.style.setProperty("--cap-scale", this.scale)
      scaleLabel.textContent = `${Math.round(this.scale * 100)}%`
      store.set("scale", String(this.scale))
    }
    $("[data-role=smaller-text]").addEventListener("click", () => setScale(this.scale - 0.15))
    $("[data-role=bigger-text]").addEventListener("click", () => setScale(this.scale + 0.15))
    scaleLabel.addEventListener("click", () => setScale(1))
    setScale(this.scale)

    // Pause after each line, with a replay of it (the round button on the picture).
    const study = $("[data-role=study]")
    const replay = $("[data-role=replay]")
    const setStudy = (on) => {
      this.study = on
      study.checked = on
      replay.hidden = !on
      store.set("study", on ? "1" : "0")
      this.pausedAt = -1
      this.watching = -1
    }
    study.addEventListener("change", () => setStudy(study.checked))
    replay.addEventListener("click", () => this.replay())
    setStudy(this.study)

    // Peek: the other tracks blurred until you click them.
    const peek = $("[data-role=peek]")
    const setPeek = (on) => {
      this.peek = on
      peek.checked = on
      this.ui.dataset.peek = on ? "true" : "false"
      store.set("peek", on ? "1" : "0")
    }
    peek.addEventListener("change", () => setPeek(peek.checked))
    setPeek(this.peek)
    this.el.addEventListener("click", (e) => {
      const trans = e.target.closest && e.target.closest(".study-trans")
      if (trans) trans.toggleAttribute("data-revealed")
    })
  },

  openPop(name) {
    const pop = this.pops[name]
    this.dismissTip()
    pop.menu.hidden = false
    pop.btn.setAttribute("aria-expanded", "true")
    pop.btn.classList.add("btn-active")
    this.syncBackdrop()
  },

  closePops() {
    if (!this.pops) return
    for (const pop of Object.values(this.pops)) {
      pop.menu.hidden = true
      pop.btn.setAttribute("aria-expanded", "false")
      pop.btn.classList.remove("btn-active")
    }
    this.syncBackdrop()
  },

  // The dim layer behind a sheet (a phone's menus and list); a wide screen's menus have none.
  syncBackdrop() {
    if (!this.backdrop || !this.pops) return
    const menu = Object.values(this.pops).some((p) => !p.menu.hidden)
    const phoneMenu = menu && window.matchMedia("(max-width: 639px)").matches
    const sheet = !this.wide.matches && this.ui.dataset.sheet === "open"
    this.backdrop.hidden = !(phoneMenu || sheet)
  },

  // ── the list ───────────────────────────────────────────────────────

  // The first track: its lines, with the words and the other tracks under each, and the language
  // (so the words know what to ask).
  setPrimary(vtt, name, track) {
    const p = this.p
    p.cues = parseVtt(vtt)
    p.lang = shortLang(track.lang)
    p.url = track.url
    p.label = name || "Subtitles"
    p.idx = -1
    p.live = []
    this.pausedAt = -1
    this.watching = -1
    this.overlayKey = ""
    if (p.lang === "ja") loadKuromoji().then(() => this.retokenize())
    this.buildRows()
  },

  // Another track on: its lines go under the first one's, in the overlay and in the list.
  setExtra(e, vtt, track) {
    e.cues = parseVtt(vtt)
    e.lang = shortLang(track.lang)
    e.url = track.url
    this.overlayKey = ""
    if (e.lang === "ja") loadKuromoji().then(() => this.retokenize())
    this.buildRows()
  },

  // Kuromoji finished loading: the words in what is already on screen are cut again, better.
  retokenize() {
    if (!this.p.cues.length && !this.extras.length) return
    this.buildRows()
    this.overlayKey = ""
    this.tick()
  },

  clearMain() {
    const p = this.p
    p.cues = []
    p.url = null
    p.lang = ""
    p.loading = null
    p.rows = []
    p.idx = -1
    p.live = []
    this.overlayKey = ""
    if (this.overlay) this.overlay.textContent = ""
  },

  // What the other tracks say while a line is said: those lines whose middle falls within it (a
  // long cue — the opening song — would otherwise swallow every line spoken under it), at most
  // three; failing that, any that overlap it by more than half of their own length. One entry
  // per track that has something.
  translationsFor(cue) {
    const mid = (c) => (c.start + c.end) / 2
    const out = []
    for (const e of this.extras) {
      let hits = e.cues.filter((c) => mid(c) >= cue.start - 0.3 && mid(c) <= cue.end + 0.3)
      if (!hits.length) {
        hits = e.cues.filter((c) => Math.min(c.end, cue.end) - Math.max(c.start, cue.start) > (c.end - c.start) / 2)
      }
      if (hits.length) out.push({text: hits.slice(0, 3).map((c) => c.text).join(" "), lang: e.lang})
    }
    return out
  },

  buildRows() {
    const p = this.p
    this.list.textContent = ""
    p.rows = []

    this.title.textContent = p.label || "Subtitles"
    this.empty.hidden = p.cues.length > 0
    this.empty.textContent = p.cues.length ? "" : "No subtitle lines found in that file."
    this.count.textContent = p.cues.length ? `0 / ${p.cues.length}` : ""

    // One row per cue, built once (again when the words are cut better, or a translation
    // arrives). Highlighting only ever flips attributes after this.
    const frag = document.createDocumentFragment()
    p.cues.forEach((cue, i) => {
      const row = document.createElement("div")
      row.className = "study-row"
      row.dataset.idx = i
      row.dataset.state = "future"

      const time = document.createElement("span")
      time.className = "study-time"
      time.textContent = formatTime(cue.start)

      const main = document.createElement("div")
      main.className = "study-main"
      const text = document.createElement("div")
      text.className = "study-text"
      text.dataset.lang = p.lang
      fillLine(text, cue.text, p.lang)
      main.appendChild(text)

      for (const tr of this.translationsFor(cue)) {
        const t = document.createElement("div")
        t.className = "study-trans"
        t.dataset.lang = tr.lang
        fillLine(t, tr.text, tr.lang)
        main.appendChild(t)
      }

      // Only the ▶ (and the time) plays from here: clicking the words selects and looks them up.
      const play = document.createElement("button")
      play.type = "button"
      play.className = "study-play"
      play.textContent = "▶"
      play.title = "Play from this line"

      row.append(time, main, play)
      frag.appendChild(row)
      p.rows.push(row)
    })
    this.list.appendChild(frag)

    this.setFollow(true)
    p.idx = -1
    p.live = []
    this.tick()
    if (p.idx >= 0) this.scrollToIndex(p.idx, false)
  },

  // The line you are on changed. Rows before it are "past", it is "current", the rest are
  // "future"; only the rows between the old and new position can have changed state.
  setIndex(idx) {
    const p = this.p
    const prev = p.idx
    const from = Math.max(0, Math.min(prev, idx))
    const to = Math.min(p.rows.length - 1, Math.max(prev, idx))

    for (let i = from; i <= to; i++) {
      p.rows[i].dataset.state = i < idx ? "past" : i === idx ? "current" : "future"
    }
    p.idx = idx
    this.count.textContent = `${idx + 1} / ${p.cues.length}`

    if (this.follow && idx >= 0) {
      // A line coming up in order glides; a seek jumps, so it doesn't scroll for a second.
      this.scrollToIndex(idx, !this.video.paused && idx === prev + 1)
    }
  },

  // The line(s) being spoken right now are brighter than the one just heard.
  setLive(live) {
    const p = this.p
    if (live.length === p.live.length && live.every((v, i) => v === p.live[i])) return
    for (const i of p.live) if (p.rows[i]) delete p.rows[i].dataset.live
    for (const i of live) if (p.rows[i]) p.rows[i].dataset.live = "true"
    p.live = live
  },

  // Centre a row in the list — scrolling the list itself, never the page (scrollIntoView
  // would walk up and shove the video off screen).
  scrollToIndex(i, smooth) {
    const row = this.p.rows[i]
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

    this.list.addEventListener("click", (e) => {
      const trans = e.target.closest(".study-trans")
      if (trans) return // the shared handler reveals it
      const hit = e.target.closest(".study-play, .study-time")
      if (!hit) return
      const row = hit.closest(".study-row")
      this.seekToLine(this.p.cues[Number(row.dataset.idx)], row.querySelector(".study-play"))
      this.resume()
    })

    this.pill.addEventListener("click", () => this.resume())
  },

  // Play from a line. The remux is written while you watch: if that part is not there yet the
  // browser would clamp the seek to what is, so the ▶ shows ⏳ and waits until it is reachable.
  seekToLine(cue, btn) {
    if (!cue) return
    const v = this.video
    const target = Math.max(0, cue.start + this.offset)
    clearTimeout(this.seekWait)
    if (this.seekBtn && this.seekBtn !== btn) this.seekBtn.textContent = "▶"

    const reach = () => { const r = v.seekable; return r && r.length ? r.end(r.length - 1) : 0 }
    const go = () => {
      v.currentTime = target
      v.play().catch(() => {})
      this.pausedAt = -1
      this.watching = -1
      if (btn) btn.textContent = "▶"
      this.seekBtn = null
    }
    if (target <= reach() + 0.5) return go()

    if (btn) { btn.textContent = "⏳"; this.seekBtn = btn }
    let tries = 600
    const wait = () => {
      if (target <= reach() + 0.5) return go()
      if (--tries <= 0) { if (btn) btn.textContent = "▶"; this.seekBtn = null; return }
      this.seekWait = setTimeout(wait, 500)
    }
    wait()
  },

  setFollow(on) {
    this.follow = on
    this.pill.hidden = on || this.p.idx < 0
  },

  resume() {
    clearTimeout(this.resumeTimer)
    this.setFollow(true)
    if (this.p.idx >= 0) this.scrollToIndex(this.p.idx, true)
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
      this.setPrimary(vtt, "Demo — français", {lang: "fr", url: "demo"})
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
    this.clearMain()
    this.extras = []
    this.cache.clear()
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

  // ── the subtitle tracks ────────────────────────────────────────────

  // Any number of the release's tracks can be on at once, in the order you like: the first is the
  // one studied (its words have the dictionary, the list is its lines), the others show under it as
  // translations. Click a track to turn it on or off; ↑ on one that is on makes it the first. What
  // you chose is remembered by language and name, so the next episode starts the same way.
  setTracks(p) {
    this.tracks = p.tracks || []
    this.mediaKey = p.key || ""
    const saved = parseFloat(store.get("offset:" + this.mediaKey))
    if (!Number.isNaN(saved) && saved !== this.offset && this.setOffset) this.setOffset(saved)

    // Tracks arriving later (a provider's) do not undo what was picked by hand.
    this.apply(this.userChose ? this.selection() : this.restore(p.prefer))

    if (!this.tracks.length && !this.p.cues.length) {
      this.empty.hidden = false
      this.empty.textContent = "No subtitles came with this release."
    }
  },

  // The urls of the tracks that are on, in order.
  selection() {
    return [this.p.want, ...this.extras.map((e) => e.want)].filter(Boolean)
  },

  // What to start with: what was chosen last time (by name, else by language), or the first time
  // the user's language, with English under it when that is another language.
  restore(prefer) {
    let saved = null
    try { saved = JSON.parse(store.get("layers")) } catch {}
    if (Array.isArray(saved)) {
      const used = new Set()
      const out = []
      for (const w of saved) {
        const t =
          this.tracks.find((t) => !used.has(t.url) && t.label === w.n) ||
          this.tracks.find((t) => !used.has(t.url) && w.l && shortLang(t.lang) === w.l)
        if (t) { used.add(t.url); out.push(t.url) }
      }
      if (out.length || saved.length === 0) return out
    }
    const main = this.tracks.find((t) => prefer && shortLang(t.lang) === prefer) || this.tracks[0]
    if (!main) return []
    const out = [main.url]
    if (shortLang(main.lang) !== "en") {
      const en = this.tracks.find((t) => t.url !== main.url && shortLang(t.lang) === "en")
      if (en) out.push(en.url)
    }
    return out
  },

  // Make exactly these tracks the ones on, in this order, loading what is not loaded yet.
  apply(urls) {
    const track = (u) => this.tracks.find((t) => t.url === u)
    urls = urls.filter(track)
    const [first, ...rest] = urls

    this.p.want = first || null
    if (!first) {
      if (this.p.url && this.p.url !== "upload") this.clearMain()
    } else if (this.p.url !== first) {
      this.clearMain()
      this.p.want = first
      this.fill(this.p, track(first))
    }

    const old = new Map(this.extras.map((e) => [e.want, e]))
    for (const [u, e] of old) if (!rest.includes(u)) e.loading = null // stop loading what was turned off
    this.extras = rest.map((u) => {
      if (old.has(u)) return old.get(u)
      const t = track(u)
      const e = {cues: [], lang: shortLang(t.lang), url: null, label: t.label, want: u, loading: null}
      this.fill(e, t)
      return e
    })
    this.extras.forEach((e) => { if (!e.cues.length && !e.loading) this.fill(e, track(e.want)) })

    this.overlayKey = ""
    this.buildRows()
    this.renderMenu()
  },

  // Put a track's lines into a layer: from what was downloaded before, or by loading it.
  fill(target, track) {
    if (!track) return
    const text = this.cache.get(track.url)
    if (text) this.finish(target, text, track)
    else this.loadTrack(target, track)
  },

  finish(target, text, track) {
    if (target === this.p) this.setPrimary(text, track.label, track)
    else this.setExtra(target, text, track)
  },

  // The menu of tracks: what is on, in order (the first is the main one), then the languages that
  // can be added — one row each, opening to its versions when a language has several.
  renderMenu() {
    const box = this.subsList
    box.textContent = ""
    const el = (tag, cls, text) => {
      const e = document.createElement(tag)
      if (cls) e.className = cls
      if (text != null) e.textContent = text
      return e
    }
    const langOf = (t) => String(t.label).split(" · ")[0]
    const versionOf = (t) => String(t.label).split(" · ").slice(1).join(" · ")

    const on = this.selection().map((u) => this.tracks.find((t) => t.url === u)).filter(Boolean)
    const names = []
    for (const t of on) if (!names.includes(langOf(t))) names.push(langOf(t))
    this.subsLabel.textContent = on.length ? names.slice(0, 2).join(" + ") + (names.length > 2 ? ` +${names.length - 2}` : "") : this.tracks.length ? "Subtitles off" : "No subtitles"
    if (!this.tracks.length) {
      box.appendChild(el("p", "p-3 text-sm opacity-60", "This release came with no subtitle tracks."))
      return
    }

    if (on.length) {
      box.appendChild(el("div", "study-label", "Showing"))
      on.forEach((t, k) => {
        const row = el("div", "sub-row")
        row.appendChild(el("span", "sub-badge" + (k ? " second" : ""), k ? String(k + 1) : "★"))
        const name = el("span", "sub-name", langOf(t))
        if (versionOf(t)) name.appendChild(el("span", "sub-sub", "  " + versionOf(t)))
        row.appendChild(name)
        if (k > 0) {
          const up = el("button", "btn btn-xs btn-ghost btn-square", "↑")
          up.type = "button"
          up.title = "Make this the main subtitles"
          up.addEventListener("click", () => this.promote(this.tracks.indexOf(t)))
          row.appendChild(up)
        }
        const x = el("button", "btn btn-xs btn-ghost btn-square", "✕")
        x.type = "button"
        x.title = "Turn this track off"
        x.addEventListener("click", () => this.toggle(this.tracks.indexOf(t)))
        row.appendChild(x)
        box.appendChild(row)
      })
    }

    const groups = []
    for (const t of this.tracks) {
      if (on.includes(t)) continue
      let g = groups.find((g) => g.name === langOf(t))
      if (!g) groups.push((g = {name: langOf(t), items: []}))
      g.items.push(t)
    }
    if (groups.length) box.appendChild(el("div", "study-label", on.length ? "Add" : "Choose"))
    for (const g of groups) {
      const add = (t) => this.toggle(this.tracks.indexOf(t))
      if (g.items.length === 1) {
        const row = el("button", "sub-row")
        row.type = "button"
        row.appendChild(el("span", "sub-badge second", "+"))
        const name = el("span", "sub-name", g.name)
        if (versionOf(g.items[0])) name.appendChild(el("span", "sub-sub", "  " + versionOf(g.items[0])))
        row.appendChild(name)
        row.addEventListener("click", () => add(g.items[0]))
        box.appendChild(row)
      } else {
        const open = this.openLang === g.name
        const row = el("button", "sub-row")
        row.type = "button"
        row.appendChild(el("span", "sub-badge second", open ? "–" : "+"))
        const name = el("span", "sub-name", g.name)
        name.appendChild(el("span", "sub-sub", `  ${g.items.length} versions`))
        row.appendChild(name)
        row.addEventListener("click", () => { this.openLang = open ? null : g.name; this.renderMenu() })
        box.appendChild(row)
        if (open) {
          const list = el("div", "sub-variants")
          g.items.forEach((t, i) => {
            const v = el("button", "sub-row", versionOf(t) || `Version ${i + 1}`)
            v.type = "button"
            v.addEventListener("click", () => add(t))
            list.appendChild(v)
          })
          box.appendChild(list)
        }
      }
    }

    if (on.length) {
      const off = el("button", "sub-row", "Turn subtitles off")
      off.type = "button"
      off.classList.add("opacity-70")
      off.addEventListener("click", () => this.setSelection([]))
      box.appendChild(off)
    }
  },

  toggle(i) {
    const u = this.tracks[i].url
    const on = this.selection()
    this.setSelection(on.includes(u) ? on.filter((x) => x !== u) : [...on, u])
  },

  promote(i) {
    const u = this.tracks[i].url
    this.setSelection([u, ...this.selection().filter((x) => x !== u)])
  },

  setSelection(urls) {
    this.userChose = true
    const desc = urls.map((u) => this.tracks.find((t) => t.url === u)).filter(Boolean).map((t) => ({l: shortLang(t.lang), n: t.label}))
    store.set("layers", JSON.stringify(desc))
    this.apply(urls)
    this.tick()
  },

  // A release's tracks are written by ffmpeg while the player already runs: the file may not
  // exist yet (404) and then grows as it reads on. So it is fetched again every few seconds
  // until it stops getting longer. `target` is the main layer or one of the extras.
  async loadTrack(target, track) {
    target.loading = track.url
    let seen = -1
    let still = 0
    const main = target === this.p

    for (let tries = 0; tries < 75 && target.loading === track.url; tries++) {
      try {
        const res = await fetch(track.url, {credentials: "same-origin", cache: "no-store"})

        if (res.ok) {
          const text = await res.text()
          if (target.loading !== track.url) return
          const n = parseVtt(text).length
          if (n === 0) {
            if (main && !target.cues.length) {
              this.empty.hidden = false
              this.empty.textContent = "Reading the subtitles out of the release…"
            }
          } else if (n > seen) {
            seen = n
            still = 0
            this.cache.set(track.url, text)
            this.finish(target, text, track)
          } else if (++still >= 3) return
        } else if (res.status === 404) {
          if (main && !target.cues.length) {
            this.empty.hidden = false
            this.empty.textContent = "Reading the subtitles out of the release…"
          }
        } else {
          if (main) this.title.textContent = "Couldn't load that subtitle track."
          return
        }
      } catch {
        if (main) this.title.textContent = "Couldn't load that subtitle track."
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
