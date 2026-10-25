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
import {bindTransport} from "./transport.js"

// After you scroll the list it stops following the video, then picks the current line back up
// on its own once you've been idle this long.
const FOLLOW_RESUME_MS = 5000
// How long a word must be hovered before the video stops and the card opens (a sweep of the
// mouse across the line should not).
const DWELL_MS = 300
// How long a card stays once the pointer is on neither the word nor the card.
const AWAY_MS = 1500

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

// The languages offered for the audio of a title (the full-screen player's audio menu).
const AUDIO_LANGS = [["en", "English"], ["fr", "French"], ["ja", "Japanese"], ["es", "Spanish"],
  ["de", "German"], ["it", "Italian"], ["pt", "Portuguese"], ["ru", "Russian"], ["ko", "Korean"], ["zh", "Chinese"]]

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
    this.nextBtn = this.el.querySelector("[data-role=next-btn]")
    this.prevBtn = this.el.querySelector("[data-role=prev-btn]")
    this.audioBtn = this.el.querySelector("[data-role=audio-btn]")
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
    // Tracks that are on but only in the list at the side, not over the picture (urls).
    this.offVideo = new Set()
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
    clearInterval(this.watchTimer)
    if (this.onMove) {
      document.removeEventListener("mousemove", this.onMove)
      document.removeEventListener("contextmenu", this.onAway)
      document.documentElement.removeEventListener("mouseleave", this.onAway)
      window.removeEventListener("blur", this.onAway)
    }
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
    const hid = [...this.offVideo].join(",")
    const key = this.p.url
      ? `${hid}|${this.p.url}|${this.extras.map((e) => e.url).join(",")}|${tokenizer ? 1 : 0}|${live.join(",")}|${extraLive.map((l) => l.join(",")).join(";")}`
      : "off"
    if (key === this.overlayKey) return
    this.overlayKey = key
    if (!this.hovering) this.hideTip()
    this.overlay.textContent = ""
    // The card was for a word that has just been taken off the screen.
    if (this.tipFor && !this.tipFor.isConnected) this.dismissTip()
    if (!this.p.url) return

    for (const i of this.offVideo.has(this.p.want) ? [] : live) {
      const line = document.createElement("div")
      line.className = "study-line"
      line.dataset.lang = this.p.lang
      fillLine(line, this.p.cues[i].text, this.p.lang)
      this.overlay.appendChild(line)
    }
    // The translation under a line is the one the side list pairs with it (they are separate
    // files with their own timings, so each one's own "now" can be the next or previous line).
    // Between primary lines there is nothing to pair with: each track then shows its own.
    const paired = live.length ? live.map((i) => this.pairFor(this.p.cues[i])) : null
    this.extras.forEach((e, k) => {
      if (this.offVideo.has(e.want)) return
      // Several primary lines can be live at once and share a translation: each of its lines once.
      const idx = paired ? [...new Set(paired.flatMap((row) => row[k]))].sort((x, y) => x - y) : extraLive[k]
      const text = this.joinCues(k, idx)
      if (!text) return
      const trans = document.createElement("div")
      trans.className = "study-trans study-line"
      trans.dataset.lang = e.lang
      fillLine(trans, text, e.lang)
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

    // Leaving a word is not always announced: a right click, a context menu, another window
    // taking focus, or the pointer leaving the page can all swallow the "mouseout", and the card
    // would then stay for good. So the pointer is also watched directly, and a card the pointer
    // is not on (neither its word nor the card) goes after a moment, whatever else happened.
    this.pointerOn = false
    this.awaySince = 0
    this.onMove = (e) => { this.pointerOn = !!(e.target.closest && e.target.closest(".study-word, .study-tip")) }
    this.onAway = () => { this.pointerOn = false }
    document.addEventListener("mousemove", this.onMove, {passive: true})
    document.addEventListener("contextmenu", this.onAway)
    document.documentElement.addEventListener("mouseleave", this.onAway)
    window.addEventListener("blur", this.onAway)
    this.watchTimer = setInterval(() => this.checkTip(), 300)
  },

  checkTip() {
    if (!this.tipFor || this.pointerOn) {
      this.awaySince = 0
      return
    }
    this.awaySince = this.awaySince || Date.now()
    if (Date.now() - this.awaySince >= AWAY_MS) {
      this.awaySince = 0
      this.dismissTip()
    }
  },

  wordEnter(w) {
    clearTimeout(this.leaveTimer)
    this.pointerOn = true
    // Already on its way (or already showing): nothing to start. Anything else — including a word
    // left and come back to before its card opened — starts afresh.
    if (this.currentWord === w && (this.tipFor === w || this.dwellTimer)) return
    clearTimeout(this.dwellTimer)
    this.dwellTimer = null
    this.currentWord = w
    if (this.hovering) {
      this.showTip(w) // already reading: the next word at once
    } else {
      this.dwellTimer = setTimeout(() => {
        this.dwellTimer = null
        if (this.currentWord !== w || !w.isConnected) return
        this.wasPlaying = !this.video.paused
        this.video.pause()
        this.hovering = true
        this.showTip(w)
      }, DWELL_MS)
    }
  },

  wordLeave() {
    clearTimeout(this.dwellTimer)
    this.dwellTimer = null
    // No card yet: nothing to close, and coming back to this word must be able to start again.
    if (!this.tipFor) this.currentWord = null
    if (this.pinned) return
    this.leaveTimer = setTimeout(() => this.dismissTip(), 250)
  },

  // Close the card; if the video was only stopped for the card, let it go on.
  dismissTip() {
    clearTimeout(this.dwellTimer)
    this.dwellTimer = null
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
    // A word that is no longer on screen (its line has moved on) or has no text has nothing to
    // say, and a card for it has nowhere to sit but the corner of the picture.
    if (!word.isConnected || !text.trim()) {
      this.hideTip()
      return
    }
    this.tipFor = word
    for (const el of this.el.querySelectorAll("[data-on]")) delete el.dataset.on
    word.dataset.on = "true"

    this.fillTip(word, text, null)
    const lang = this.langOf(word)
    const result = await this.define(lang, text)
    if (this.tipFor === word && word.isConnected) this.fillTip(word, text, result)
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
    if (!word.isConnected) {
      this.hideTip()
      return
    }
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

    // ── the lines sit on the bottom edge, and step up above the timeline while the player's own
    // controls are showing (they come with the pointer, and stay while paused).
    let idle
    const wake = () => {
      this.stage.dataset.active = "1"
      clearTimeout(idle)
      if (!this.video.paused) idle = setTimeout(() => delete this.stage.dataset.active, 2800)
    }
    for (const ev of ["mousemove", "pointerdown", "touchstart"]) this.stage.addEventListener(ev, wake, {passive: true})
    this.stage.addEventListener("mouseleave", () => {
      clearTimeout(idle)
      if (!this.video.paused) idle = setTimeout(() => delete this.stage.dataset.active, 400)
    })
    this.video.addEventListener("pause", () => { clearTimeout(idle); this.stage.dataset.active = "1" })
    this.video.addEventListener("play", wake)
    this.video.addEventListener("ended", () => { this.stage.dataset.active = "1" })
    if (this.video.paused) this.stage.dataset.active = "1"

    // ── the full-screen player (the watch page): its own bar instead of the video's, and a button
    // that closes it — back to the page before, or to the title when there was none.
    const immersive = this.el.dataset.immersive === "true"
    if (immersive) {
      bindTransport(this.el, this.video, this.stage)
      $("[data-role=close]").addEventListener("click", () => {
        if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
        if (history.length > 1) history.back()
        else window.location.assign(this.el.dataset.home || "/home")
      })
    }

    // ── theater and fullscreen
    const theater = $("[data-role=theater]")
    const setTheater = (on) => {
      this.ui.dataset.theater = on ? "true" : "false"
      if (theater) {
        theater.setAttribute("aria-pressed", String(on))
        theater.classList.toggle("btn-primary", on)
      }
      store.set("theater", on ? "1" : "0")
      if (this.tipFor) this.placeTip(this.tipFor)
    }
    // (The full-screen player has no theater button: it is theater already.)
    if (theater) theater.addEventListener("click", () => setTheater(this.ui.dataset.theater !== "true"))
    setTheater(!immersive && store.get("theater") === "1")

    // Fullscreen is the picture with its subtitles (the card goes in with it), not the bare video.
    $("[data-role=fullscreen]").addEventListener("click", () => {
      if (document.fullscreenElement) document.exitFullscreen()
      else if (immersive && this.el.requestFullscreen) this.el.requestFullscreen().catch(() => {})
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
    const compact = $("[data-role=compact]")
    const showList = () => this.p.idx >= 0 && requestAnimationFrame(() => this.scrollToIndex(this.p.idx, false))
    const reflect = () => {
      const open = this.wide.matches ? this.ui.dataset.panel !== "closed" : this.ui.dataset.sheet === "open"
      lines.setAttribute("aria-pressed", String(open))
      lines.classList.toggle("btn-primary", open)
      this.syncBackdrop()
    }
    this.setPanel = (state) => {
      this.ui.dataset.panel = state
      const small = state === "compact"
      compact.title = small ? "Larger" : "Smaller"
      compact.setAttribute("aria-label", small ? "Make the list larger" : "Make the list smaller")
      store.set(this.panelKey, state)
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
    compact.addEventListener("click", () => this.setPanel(this.ui.dataset.panel === "compact" ? "open" : "compact"))
    // The full-screen player remembers the list for a study session and for a plain watch
    // separately: a study session starts with it open and a plain watch with it closed, and after
    // that each starts the way it was last left.
    const studying = this.el.dataset.study === "true"
    this.panelKey = !immersive ? "panel" : studying ? "panel-study" : "panel-watch"
    const savedPanel = store.get(this.panelKey)
    const firstTime = immersive ? (studying ? "open" : "closed") : "open"
    this.setPanel(["open", "compact", "closed"].includes(savedPanel) ? savedPanel : firstTime)
    this.wide.addEventListener("change", reflect)

    // ── the two menus
    this.pops = {
      subs: {btn: $("[data-role=subs-btn]"), menu: $("[data-role=subs-menu]")},
      audio: {btn: $("[data-role=audio-btn]"), menu: $("[data-role=audio-menu]")},
      settings: {btn: $("[data-role=settings-btn]"), menu: $("[data-role=settings-menu]")},
    }
    if ($("[data-role=ep-btn]")) this.pops.eps = {btn: $("[data-role=ep-btn]"), menu: $("[data-role=ep-menu]")}
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
      const inside = e.composedPath().some((n) => n.classList && (n.classList.contains("study-pop") || n.matches("[data-role=subs-btn], [data-role=audio-btn], [data-role=settings-btn], [data-role=ep-btn]")))
      if (!inside) this.closePops()
    })
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { this.closePops(); if (!this.wide.matches) this.setSheet(false) }
    })

    // ── the next episode: the page finds its sources and starts the best one
    this.nextBtn.addEventListener("click", () => this.pushEvent("next", {}))
    this.prevBtn.addEventListener("click", () => this.pushEvent("previous", {}))
    this.el.querySelector("[data-role=subs-off]").addEventListener("click", () => this.setSelection([]))

    // ── audio tracks (a dual-audio release), on whichever player is in use
    this.video.addEventListener("loadedmetadata", () => this.refreshAudio())
    const native = this.video.audioTracks
    if (native && native.addEventListener) {
      native.addEventListener("addtrack", () => this.refreshAudio())
      native.addEventListener("change", () => this.refreshAudio())
    }

    // ── settings: timing (a file made for another cut), text size, study mode, peek
    const offsetLabel = $("[data-role=offset]")
    const offsetInput = $("[data-role=offset-input]")
    const offsetReset = $("[data-role=offset-reset]")
    this.setOffset = (value) => {
      this.offset = Math.round(value * 100) / 100
      offsetLabel.textContent = `${this.offset > 0 ? "+" : ""}${this.offset}s`
      offsetReset.hidden = this.offset === 0
      store.set("offset:" + (this.mediaKey || ""), String(this.offset))
      this.overlayKey = ""
      this.tick()
    }
    for (const b of this.el.querySelectorAll("[data-role=nudge]")) {
      b.addEventListener("click", () => this.setOffset(this.offset + parseFloat(b.dataset.step)))
    }
    offsetReset.addEventListener("click", () => this.setOffset(0))
    // The number is a button that turns into a box: type seconds ("-1.3", "+0.4", "2"), Enter to
    // set it, Escape to leave it as it was.
    const closeInput = () => { offsetInput.hidden = true; offsetLabel.hidden = false }
    offsetLabel.addEventListener("click", () => {
      offsetLabel.hidden = true
      offsetInput.hidden = false
      offsetInput.value = String(this.offset)
      offsetInput.focus()
      offsetInput.select()
    })
    offsetInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        const v = parseFloat(offsetInput.value.replace(",", ".").replace("−", "-"))
        if (!Number.isNaN(v)) this.setOffset(Math.max(-600, Math.min(600, v)))
        closeInput()
      } else if (e.key === "Escape") {
        e.stopPropagation()
        closeInput()
      }
    })
    offsetInput.addEventListener("blur", () => {
      const v = parseFloat(offsetInput.value.replace(",", ".").replace("−", "-"))
      if (!offsetInput.hidden && !Number.isNaN(v)) this.setOffset(Math.max(-600, Math.min(600, v)))
      closeInput()
    })

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

    // How the lines look: colour, how solid the text and the box behind it are, the edge. Kept for
    // every video in this browser (like the size above), applied as variables on the player.
    const EDGES = {
      none: "none",
      shadow: "0 1px 2px #000, 0 0 5px rgb(0 0 0 / 0.8)",
      outline: "-1px -1px 0 #000, 1px -1px 0 #000, -1px 1px 0 #000, 1px 1px 0 #000, 0 0 3px #000",
    }
    const CAP_DEFAULT = {color: "#ffffff", text: 100, bg: 66, edge: "shadow"}
    let caps = {...CAP_DEFAULT}
    try { caps = {...CAP_DEFAULT, ...JSON.parse(store.get("caption") || "{}")} } catch {}
    if (!EDGES[caps.edge]) caps.edge = CAP_DEFAULT.edge
    const colorInput = $("[data-role=cap-color]")
    const textRange = $("[data-role=cap-text]")
    const bgRange = $("[data-role=cap-bg]")
    const applyCaps = (save = true) => {
      this.ui.style.setProperty("--cap-color", caps.color)
      this.ui.style.setProperty("--cap-text", `${caps.text}%`)
      this.ui.style.setProperty("--cap-bg", String(caps.bg / 100))
      this.ui.style.setProperty("--cap-edge", EDGES[caps.edge])
      colorInput.value = caps.color
      textRange.value = caps.text
      bgRange.value = caps.bg
      $("[data-role=cap-text-out]").textContent = `${caps.text}%`
      $("[data-role=cap-bg-out]").textContent = `${caps.bg}%`
      for (const b of this.el.querySelectorAll("[data-role=cap-swatch]"))
        b.toggleAttribute("data-on", b.dataset.color === caps.color)
      for (const b of this.el.querySelectorAll("[data-role=cap-edge]"))
        b.classList.toggle("btn-primary", b.dataset.edge === caps.edge)
      if (save) store.set("caption", JSON.stringify(caps))
    }
    for (const b of this.el.querySelectorAll("[data-role=cap-swatch]"))
      b.addEventListener("click", () => { caps.color = b.dataset.color; applyCaps() })
    colorInput.addEventListener("input", () => { caps.color = colorInput.value; applyCaps() })
    textRange.addEventListener("input", () => { caps.text = Number(textRange.value); applyCaps() })
    bgRange.addEventListener("input", () => { caps.bg = Number(bgRange.value); applyCaps() })
    for (const b of this.el.querySelectorAll("[data-role=cap-edge]"))
      b.addEventListener("click", () => { caps.edge = b.dataset.edge; applyCaps() })
    $("[data-role=cap-reset]").addEventListener("click", () => { caps = {...CAP_DEFAULT}; applyCaps() })
    applyCaps(false)

    // Pause after each line, with a replay of it (the round button on the picture).
    const study = $("[data-role=study]")
    const replay = $("[data-role=replay]")
    const quick = $("[data-role=study-quick]")
    const setStudy = (on) => {
      this.study = on
      study.checked = on
      quick.classList.toggle("btn-primary", on)
      quick.setAttribute("aria-pressed", String(on))
      replay.hidden = !on
      store.set("study", on ? "1" : "0")
      this.pausedAt = -1
      this.watching = -1
    }
    study.addEventListener("change", () => setStudy(study.checked))
    quick.addEventListener("click", () => setStudy(!this.study))
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

  // The season's episodes, from what the page put on the root; a pick goes to the server.
  buildEpisodes() {
    const box = this.el.querySelector("[data-role=ep-list]")
    let eps = []
    try { eps = JSON.parse(this.el.dataset.episodes || "[]") } catch {}
    box.textContent = ""
    let now = null
    for (const e of eps) {
      const row = document.createElement("button")
      row.type = "button"
      row.className = "sub-row"
      row.disabled = !e.ok
      const badge = document.createElement("span")
      badge.className = "sub-badge" + (e.now ? "" : " second")
      badge.textContent = e.now ? "▶" : ""
      const name = document.createElement("span")
      name.className = "sub-name"
      name.textContent = `${e.n}. ${e.name || "Episode " + e.n}`
      row.append(badge, name)
      if (!e.ok) row.style.opacity = "0.4"
      if (e.now) now = row
      else row.addEventListener("click", () => { this.closePops(); this.pushEvent("goto", {episode: e.n}) })
      box.appendChild(row)
    }
    if (!eps.length) box.textContent = "No episode list for this one."
    if (now) requestAnimationFrame(() => { box.scrollTop = now.offsetTop - box.clientHeight / 2 })
  },

  openPop(name) {
    const pop = this.pops[name]
    if (name === "eps") this.buildEpisodes()
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
    const out = []
    this.pairFor(cue).forEach((idx, k) => {
      if (idx.length) out.push({text: this.joinCues(k, idx), lang: this.extras[k].lang})
    })
    return out
  },

  joinCues(k, idx) {
    return idx.map((i) => this.extras[k].cues[i].text).join(" ")
  },

  // The same, one list of cue numbers per extra track in order (empty where it has nothing): the
  // pairing the side list shows, and the one the picture shows too, so the two never disagree.
  pairFor(cue) {
    const mid = (c) => (c.start + c.end) / 2
    return this.extras.map((e) => {
      let hits = []
      e.cues.forEach((c, i) => { if (mid(c) >= cue.start - 0.3 && mid(c) <= cue.end + 0.3) hits.push(i) })
      if (!hits.length) {
        e.cues.forEach((c, i) => {
          if (Math.min(c.end, cue.end) - Math.max(c.start, cue.start) > (c.end - c.start) / 2) hits.push(i)
        })
      }
      return hits.slice(0, 3)
    })
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
    this.prevBtn.hidden = !p.prev
    this.prevBtn.title = p.prev ? `Play the previous episode (${p.prev})` : "Play the previous episode"
    this.nextBtn.hidden = !p.next
    const label = this.nextBtn.querySelector("[data-role=next-label]")
    if (label) label.textContent = p.next || ""
    this.nextBtn.title = p.next ? `Play the next episode (${p.next})` : "Play the next episode"
    const osKey = JSON.stringify([p.os, p.os_langs, p.key])
    if (osKey !== this.osKey) {
      this.osKey = osKey
      this.os = {state: p.os || "off", langs: p.os_langs || [], lang: null, results: null, busy: false, error: null, open: false}
      this.renderOs()
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
    this.resetAudio()

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
      hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, () => this.refreshAudio())
      hls.on(Hls.Events.AUDIO_TRACK_SWITCHED, () => this.refreshAudio())
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

  // ── audio tracks ───────────────────────────────────────────────────

  resetAudio() {
    this.audioBtn.hidden = true
    this.audioApplied = false
    this.closePops && this.closePops()
  },

  // The audio tracks of what is playing — hls.js's, or the browser's own (Safari plays the
  // stream natively) — as `[{i, name, active}]`.
  audioList() {
    const names = (t) => {
      const lang = shortLang(t.lang || t.language)
      const nice = {ja: "Japanese", en: "English", fr: "French", es: "Spanish", de: "German", it: "Italian", pt: "Portuguese", ru: "Russian", ko: "Korean", zh: "Chinese"}[lang]
      const raw = String(t.name || t.label || "").replace(/_/g, " ").trim()
      return nice || (raw ? raw.charAt(0).toUpperCase() + raw.slice(1) : "") || t.lang || t.language || ""
    }
    if (this.hls && this.hls.audioTracks && this.hls.audioTracks.length) {
      return this.hls.audioTracks.map((t, i) => ({i, name: names(t) || `Track ${i + 1}`, lang: t.lang, active: i === this.hls.audioTrack}))
    }
    const native = this.video.audioTracks
    if (native && native.length) {
      return Array.from({length: native.length}, (_, i) => ({i, name: names(native[i]) || `Track ${i + 1}`, lang: native[i].language, active: !!native[i].enabled}))
    }
    return []
  },

  // The two letters for an audio track — JA, EN — from its language, or from its name when that
  // names a language ("Japanese"), else the first letters of the name.
  audioCode(t) {
    const byName = {japanese: "JA", english: "EN", french: "FR", spanish: "ES", german: "DE", italian: "IT", portuguese: "PT", russian: "RU", korean: "KO", chinese: "ZH", dutch: "NL", polish: "PL", turkish: "TR", arabic: "AR", swedish: "SV"}
    const first = String(t.name || "").toLowerCase().split(/[\s·(]/)[0]
    return (shortLang(t.lang) || (byName[first] || shortLang(first)) || String(t.name || "?").replace(/\s+/g, "").slice(0, 3)).toUpperCase()
  },

  setAudio(i) {
    if (this.hls && this.hls.audioTracks && this.hls.audioTracks.length) {
      this.hls.audioTrack = i
    } else if (this.video.audioTracks) {
      for (let k = 0; k < this.video.audioTracks.length; k++) this.video.audioTracks[k].enabled = k === i
    }
    const t = this.audioList().find((x) => x.i === i)
    if (t) store.set("audio", t.name)
    this.refreshAudio()
  },

  // The button shows up when there is a choice (two tracks or more); the one you picked last time
  // — by name — is switched to once, so the next episode sounds the same.
  refreshAudio() {
    const list = this.audioList()
    const immersive = this.el.dataset.immersive === "true"
    this.audioBtn.hidden = list.length < 2 && !immersive
    if (list.length < 2) {
      if (immersive) this.buildAudioMenu(list)
      return
    }

    if (!this.audioApplied) {
      this.audioApplied = true
      const want = store.get("audio")
      const t = want && list.find((x) => x.name === want)
      if (t && !t.active) { this.setAudio(t.i); return }
    }

    const active = list.find((x) => x.active) || list[0]
    const label = this.el.querySelector("[data-role=audio-label]")
    label.textContent = this.audioCode(active)
    this.audioBtn.title = `Audio: ${active.name}`

    this.buildAudioMenu(list)
  },

  // The release's own audio tracks, and — in the full-screen player — the other languages: a pick
  // finds this episode again with that audio (see "audio_lang" on the page).
  buildAudioMenu(list) {
    const box = this.el.querySelector("[data-role=audio-list]")
    box.textContent = ""
    for (const t of list) {
      const row = document.createElement("button")
      row.type = "button"
      row.className = "sub-row"
      const badge = document.createElement("span")
      badge.className = "sub-badge" + (t.active ? "" : " second")
      badge.textContent = t.active ? "✓" : ""
      const name = document.createElement("span")
      name.className = "sub-name"
      name.textContent = t.name
      const code = document.createElement("span")
      code.className = "sub-sub"
      code.textContent = this.audioCode(t)
      row.append(badge, name, code)
      row.addEventListener("click", () => { this.setAudio(t.i); this.closePops() })
      box.appendChild(row)
    }
    if (this.el.dataset.immersive !== "true") return
    const head = document.createElement("div")
    head.className = "study-label"
    head.textContent = "Find it in another language"
    box.appendChild(head)
    for (const [code, name] of AUDIO_LANGS) {
      const row = document.createElement("button")
      row.type = "button"
      row.className = "sub-row"
      const label = document.createElement("span")
      label.className = "sub-name"
      label.textContent = name
      row.append(label)
      row.addEventListener("click", () => { this.closePops(); this.pushEvent("audio_lang", {lang: code}) })
      box.appendChild(row)
    }
  },

  // ── the subtitle tracks ────────────────────────────────────────────

  // Any number of the release's tracks can be on at once, in the order you like: the first is the
  // one studied (its words have the dictionary, the list is its lines), the others show under it as
  // translations. Click a track to turn it on or off; ↑ on one that is on makes it the first. What
  // you chose is remembered by language and name, so the next episode starts the same way.
  setTracks(p) {
    this.tracks = p.tracks || []
    this.mediaKey = p.key || ""
    // The subtitle choice belongs to the show or film (every episode of it), not to the browser:
    // Japanese with English under it for an anime must not follow you to a French show.
    const media = p.media || ""
    if (media !== this.media) this.userChose = false
    this.media = media
    const saved = parseFloat(store.get("offset:" + this.mediaKey))
    if (!Number.isNaN(saved) && saved !== this.offset && this.setOffset) this.setOffset(saved)

    // Tracks arriving later (a provider's) do not undo what was picked by hand.
    if (!this.userChose) this.restoreOffVideo()
    queueMicrotask(() => this.tryWant())
    this.apply(this.userChose ? this.selection() : this.restore(p.prefer))

    if (!this.tracks.length && !this.p.cues.length) {
      this.empty.hidden = false
      this.empty.textContent = "No subtitles came with this release."
    }
  },

  // A track that was just fetched (from OpenSubtitles) is turned on as soon as the page has it.
  tryWant() {
    const u = this.wantSelect
    if (!u || !this.tracks.some((t) => t.url === u)) return
    this.wantSelect = null
    if (!this.selection().includes(u)) this.setSelection([...this.selection(), u])
  },

  // The OpenSubtitles box at the foot of the subtitles menu: a language, then the files it has for
  // this episode (largest download count first); a click fetches one and turns it on.
  renderOs() {
    const box = this.el.querySelector("[data-role=os-box]")
    if (!box) return
    const os = this.os
    box.textContent = ""
    box.hidden = !os || os.state === "off"
    if (box.hidden) return
    const el = (tag, cls, text) => {
      const e = document.createElement(tag)
      if (cls) e.className = cls
      if (text != null) e.textContent = text
      return e
    }
    const name = (c) => { try { return new Intl.DisplayNames(["en"], {type: "language"}).of(c) } catch { return c } }

    // Closed it is one line, so the tracks above keep the room; it opens to pick a language and a
    // file, and closes again once a file has been taken.
    const head = el("button", "btn btn-sm btn-ghost w-full justify-between", "")
    head.type = "button"
    head.appendChild(el("span", "", "OpenSubtitles — find more"))
    head.appendChild(el("span", "opacity-60", os.open ? "▴" : "▾"))
    head.setAttribute("aria-expanded", String(os.open))
    head.addEventListener("click", () => {
      os.open = !os.open
      if (!os.open) { os.lang = null; os.results = null; os.error = null }
      this.renderOs()
    })
    box.appendChild(head)
    if (!os.open) return

    const chips = el("div", "flex flex-wrap gap-1.5")
    for (const lang of os.langs) {
      const b = el("button", "btn btn-xs rounded-full" + (os.lang === lang ? " btn-primary" : ""), name(lang))
      b.type = "button"
      b.addEventListener("click", () => this.osSearch(lang))
      chips.appendChild(b)
    }
    box.appendChild(chips)
    if (os.state === "search") {
      box.appendChild(el("p", "text-xs text-warning", "Searching works; to download a file add your OpenSubtitles username and password in Settings."))
    }
    if (os.busy) box.appendChild(el("p", "text-xs opacity-60", os.lang && os.results === null ? "Searching…" : "Fetching…"))
    if (os.error) box.appendChild(el("p", "text-xs text-error", os.error))
    if (os.results) {
      if (!os.results.length) box.appendChild(el("p", "text-xs opacity-60", `No ${name(os.lang)} subtitles found for this.`))
      const list = el("div", "max-h-36 space-y-0.5 overflow-y-auto")
      for (const r of os.results) {
        const row = el("button", "flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-xs hover:bg-base-200")
        row.type = "button"
        row.appendChild(el("span", "min-w-0 flex-1 truncate", r.release || `#${r.id}`))
        row.appendChild(el("span", "shrink-0 tabular-nums opacity-50", `${r.downloads}↓`))
        row.addEventListener("click", () => this.osPick(r))
        list.appendChild(row)
      }
      box.appendChild(list)
    }
  },

  osSearch(lang) {
    const os = this.os
    os.lang = lang
    os.results = null
    os.error = null
    os.busy = true
    this.renderOs()
    this.pushEvent("os_search", {lang}, (reply) => {
      if (this.os !== os || os.lang !== lang) return
      os.busy = false
      if (reply && reply.results) os.results = reply.results
      else os.error = (reply && reply.error) || "OpenSubtitles did not answer."
      this.renderOs()
    })
  },

  osPick(r) {
    const os = this.os
    os.busy = true
    os.error = null
    this.renderOs()
    this.pushEvent("os_pick", {id: r.id, lang: os.lang, release: r.release}, (reply) => {
      if (this.os !== os) return
      os.busy = false
      if (reply && reply.track) {
        this.wantSelect = reply.track.url
        this.tryWant()
        os.open = false
        os.lang = null
        os.results = null
      } else {
        os.error = (reply && reply.error) || "OpenSubtitles would not give that file."
      }
      this.renderOs()
    })
  },

  // Which of the tracks that are on stay off the picture: remembered by name and language like
  // the choice of tracks, so the next episode starts the same way.
  restoreOffVideo() {
    let saved = []
    try { saved = JSON.parse(store.get("offvideo:" + this.media)) || [] } catch {}
    this.offVideo = new Set()
    for (const w of saved) {
      const t = this.tracks.find((t) => t.label === w.n) || this.tracks.find((t) => w.l && shortLang(t.lang) === w.l)
      if (t) this.offVideo.add(t.url)
    }
  },

  // Over the picture or only in the list at the side.
  toggleOnVideo(u) {
    if (this.offVideo.has(u)) this.offVideo.delete(u)
    else this.offVideo.add(u)
    const desc = [...this.offVideo].map((x) => this.tracks.find((t) => t.url === x)).filter(Boolean).map((t) => ({l: shortLang(t.lang), n: t.label}))
    store.set("offvideo:" + this.media, JSON.stringify(desc))
    this.userChose = true
    this.overlayKey = ""
    this.renderMenu()
    this.tick()
  },

  // The urls of the tracks that are on, in order.
  selection() {
    return [this.p.want, ...this.extras.map((e) => e.want)].filter(Boolean)
  },

  // What to start with: what was chosen last time (by name, else by language), or the first time
  // the user's language, with English under it when that is another language.
  restore(prefer) {
    let saved = null
    try { saved = JSON.parse(store.get("layers:" + this.media)) } catch {}
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
  // can be added as small buttons — one each, opening to its versions when a language has several.
  // Kept short: however much is on, the menu stays a handful of lines.
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
    // Two tracks with the same name ("English", "English") are told apart by a number.
    const nth = (t) => {
      const twins = this.tracks.filter((x) => x.label === t.label)
      return twins.length > 1 ? ` ${twins.indexOf(t) + 1}` : ""
    }
    const versionOf = (t) => (String(t.label).split(" · ").slice(1).join(" · ") || "") + (String(t.label).includes(" · ") ? nth(t) : "")
    const code = (t) => (shortLang(t.lang) || langOf(t).slice(0, 3)).toUpperCase()

    const on = this.selection().map((u) => this.tracks.find((t) => t.url === u)).filter(Boolean)
    // The bar says it in codes — JA · EN · FR — so the row never grows.
    const codes = []
    for (const t of on) if (!codes.includes(code(t))) codes.push(code(t))
    this.subsLabel.textContent = on.length
      ? codes.slice(0, 3).join(" · ") + (codes.length > 3 ? ` +${codes.length - 3}` : "")
      : this.tracks.length ? "Off" : "None"
    this.subsLabel.title = on.map((t) => t.label).join(", ")
    this.el.querySelector("[data-role=subs-off]").hidden = !on.length
    if (!this.tracks.length) {
      box.appendChild(el("p", "p-3 text-sm opacity-60", "This release came with no subtitle tracks."))
      return
    }

    if (on.length) {
      box.appendChild(el("div", "study-label", "Showing"))
      on.forEach((t, k) => {
        const row = el("div", "sub-row")
        row.appendChild(el("span", "sub-badge" + (k ? " second" : ""), k ? String(k + 1) : "★"))
        const name = el("span", "sub-name", langOf(t) + (String(t.label).includes(" · ") ? "" : nth(t)))
        if (versionOf(t)) name.appendChild(el("span", "sub-sub", "  " + versionOf(t)))
        row.appendChild(name)

        // Over the picture, or only in the list at the side.
        const onVideo = !this.offVideo.has(t.url)
        const pill = el("button", "btn btn-xs rounded-full " + (onVideo ? "btn-primary" : "btn-outline opacity-70"), "video")
        pill.type = "button"
        pill.title = onVideo ? "Shown over the picture — click to keep it in the list only" : "Only in the list — click to show it over the picture too"
        pill.setAttribute("aria-pressed", String(onVideo))
        pill.addEventListener("click", () => this.toggleOnVideo(t.url))
        row.appendChild(pill)

        // Big enough to hit: move up, move down, take off.
        const tool = (text, title, click, disabled) => {
          const b = el("button", "btn btn-square btn-ghost h-11 min-h-0 w-11 text-lg" + (disabled ? " opacity-25" : ""), text)
          b.type = "button"
          b.title = title
          b.disabled = !!disabled
          b.addEventListener("click", click)
          return b
        }
        row.appendChild(tool("↑", k === 1 ? "Make this the main subtitles" : "Move up", () => this.move(this.tracks.indexOf(t), -1), k === 0))
        row.appendChild(tool("↓", "Move down", () => this.move(this.tracks.indexOf(t), 1), k === on.length - 1))
        row.appendChild(tool("✕", "Turn this track off", () => this.toggle(this.tracks.indexOf(t)), false))
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
    if (!groups.length) return

    box.appendChild(el("div", "study-label", on.length ? "Add" : "Choose"))
    const chips = el("div", "flex flex-wrap gap-2 px-2 pb-2")
    for (const g of groups) {
      const open = this.openLang === g.name
      const chip = el("button", "btn btn-sm rounded-full" + (open ? " btn-active" : ""), `+ ${g.name}${g.items.length > 1 ? ` ·${g.items.length}` : ""}`)
      chip.type = "button"
      chip.addEventListener("click", () => {
        if (g.items.length === 1) return this.toggle(this.tracks.indexOf(g.items[0]))
        this.openLang = open ? null : g.name
        this.renderMenu()
      })
      chips.appendChild(chip)
    }
    box.appendChild(chips)

    const g = groups.find((g) => g.name === this.openLang)
    if (g) {
      box.appendChild(el("div", "study-label", `${g.name} versions`))
      const versions = el("div", "flex flex-wrap gap-2 px-2 pb-2")
      g.items.forEach((t, i) => {
        const v = el("button", "btn btn-sm btn-outline rounded-full", versionOf(t).trim() || `${g.name} ${i + 1}`)
        v.type = "button"
        v.addEventListener("click", () => this.toggle(this.tracks.indexOf(t)))
        versions.appendChild(v)
      })
      box.appendChild(versions)
    }
  },

  toggle(i) {
    const u = this.tracks[i].url
    const on = this.selection()
    this.setSelection(on.includes(u) ? on.filter((x) => x !== u) : [...on, u])
  },

  // One place up or down in the order (the first is the main one).
  move(i, delta) {
    const u = this.tracks[i].url
    const on = this.selection()
    const k = on.indexOf(u)
    const to = k + delta
    if (k < 0 || to < 0 || to >= on.length) return
    on.splice(k, 1)
    on.splice(to, 0, u)
    this.setSelection(on)
  },

  promote(i) {
    const u = this.tracks[i].url
    this.setSelection([u, ...this.selection().filter((x) => x !== u)])
  },

  setSelection(urls) {
    this.userChose = true
    const desc = urls.map((u) => this.tracks.find((t) => t.url === u)).filter(Boolean).map((t) => ({l: shortLang(t.lang), n: t.label}))
    store.set("layers:" + this.media, JSON.stringify(desc))
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
