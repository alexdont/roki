// A row of posters that scrolls sideways (the home page, on a wide screen).
//
// The chevrons are the row's own: they show on hover (CSS, at one steady level — a level that
// followed the pointer made the shade swell and fade as it moved along the row) and this keeps `data-start` /
// `data-end` true to where the row is scrolled, so the left one only shows once there is something
// to go back to and the right one goes when there is nothing further.
//
// The cards: rest the pointer on a poster and it opens into a wider card (CSS does the opening;
// the neighbours make way as flex items). Once it is open this fetches what the card shows that
// the page did not carry — length, genres, the wide picture, the trailer — and, a moment after it
// opened, swaps the picture for the trailer playing muted. Leaving the card stops it.
import {setSavedMark} from "./saved_mark"
const cache = new Map()
const STILL_MS = 260 // how long the pointer must rest on a poster before it opens
const STILL_PX = 5 // …and how little it may drift while it does
const TRAILER_MS = 1500 // how long the picture is shown before the trailer replaces it

const csrf = () => document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""

// The poster's own colour, for the glow around it under the pointer (`--tint`, app.css): the
// picture averaged on a tiny canvas, the vivid pixels counting more than the grey ones, then its
// hue kept and its lightness fixed, so a dark poster still glows in its colour. Read the first time
// the pointer reaches a poster and remembered by picture, since the same poster is on many pages.
// A picture from another origin taints the canvas and cannot be read: the glow is then neutral.
const tints = new Map()
let tintCanvas = null

const tintOf = (img) => {
  const src = img.currentSrc || img.src
  if (!src || !img.complete || !img.naturalWidth) return null
  if (tints.has(src)) return tints.get(src)
  let tint = null
  try {
    tintCanvas ||= document.createElement("canvas")
    tintCanvas.width = 8
    tintCanvas.height = 12
    const g = tintCanvas.getContext("2d", {willReadFrequently: true})
    g.drawImage(img, 0, 0, 8, 12)
    const d = g.getImageData(0, 0, 8, 12).data
    let r = 0, gg = 0, b = 0, n = 0
    for (let i = 0; i < d.length; i += 4) {
      const w = 1 + (Math.max(d[i], d[i + 1], d[i + 2]) - Math.min(d[i], d[i + 1], d[i + 2])) / 64
      r += d[i] * w; gg += d[i + 1] * w; b += d[i + 2] * w; n += w
    }
    r /= n * 255; gg /= n * 255; b /= n * 255
    const mx = Math.max(r, gg, b), mn = Math.min(r, gg, b), span = mx - mn
    let h = 0
    if (span > 0) {
      h = mx === r ? ((gg - b) / span) % 6 : mx === gg ? (b - r) / span + 2 : (r - gg) / span + 4
      h = (h * 60 + 360) % 360
    }
    const l = (mx + mn) / 2
    const sat = span === 0 ? 0 : span / (1 - Math.abs(2 * l - 1))
    tint = sat < 0.08 ? "hsl(0 0% 70%)" : `hsl(${h.toFixed(0)} ${Math.round(Math.max(sat, 0.6) * 100)}% 58%)`
  } catch (_e) {
    tint = null // tainted: another origin's picture
  }
  tints.set(src, tint)
  return tint
}

const tint = (li) => {
  if (li.style.getPropertyValue("--tint")) return
  const img = li.querySelector(".poster-card img")
  const t = img && tintOf(img)
  if (t) li.style.setProperty("--tint", t)
}

const minutes = (m) => (m ? (m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`) : "")

async function load(key) {
  if (cache.has(key)) return cache.get(key)
  try {
    const res = await fetch(`/card/${key}`, {credentials: "same-origin"})
    const info = res.ok ? await res.json() : null
    cache.set(key, info)
    return info
  } catch (_e) {
    return null
  }
}

async function libraryState(key) {
  try {
    const res = await fetch(`/library/${key}`, {credentials: "same-origin", cache: "no-store"})
    return res.ok ? await res.json() : null
  } catch (_e) {
    return null
  }
}

const setSaved = (li, saved) => {
  // The bookmark on the poster itself, drawn or taken away now.
  setSavedMark(li.querySelector("a.poster-card [data-peek]"), saved)
  const btn = li.querySelector("[data-card-save]")
  if (!btn) return
  btn.querySelector("[data-off]")?.classList.toggle("hidden", !!saved)
  btn.querySelector("[data-on]")?.classList.toggle("hidden", !saved)
  btn.setAttribute("aria-label", saved ? "Saved for later (click to remove)" : "Save for later")
  btn.title = btn.getAttribute("aria-label")
}

// The watched mark's button: the same two-state icon as the save one, and the poster greys out like
// any watched title (as the old card did), without waiting for the page.
const setWatched = (li, watched) => {
  const btn = li.querySelector("[data-card-watched]")
  if (btn) {
    btn.querySelector("[data-off]")?.classList.toggle("hidden", !!watched)
    btn.querySelector("[data-on]")?.classList.toggle("hidden", !watched)
    const series = li.dataset.key.startsWith("tv/")
    btn.setAttribute(
      "aria-label",
      watched
        ? `${series ? "Completed" : "Watched"} (click to mark as not watched)`
        : series ? "Mark as completed" : "Mark as watched"
    )
    btn.title = btn.getAttribute("aria-label")
  }
  // A list of what was watched (`data-keep-colour`) has no use for the grey: all of it is.
  if (li.hasAttribute("data-keep-colour")) return
  li.querySelector("a.poster-card")?.classList.toggle("opacity-50", !!watched)
  li.querySelector("a.poster-card img")?.classList.toggle("grayscale", !!watched)
}

// On a touch screen there is no hovering to bring a row's "See All" up: it appears on the row that
// has been touched (a tap, or the start of a swipe) and goes from it when another row is touched,
// or anywhere else on the page is. `data-touched` on the row, for the link's CSS. One row at a time.
let touched = null
let touchBound = false
const untouch = () => { touched?.removeAttribute("data-touched"); touched = null }

export const ShelfRow = {
  mounted() {
    this.scroller = this.el.querySelector("[data-row-scroller]")
    // Set a moment after the tap is over, never at the touch: on an iPhone a page that changes
    // while the finger is down counts as a hover, and that tap's click is withheld until a second
    // tap — a poster in a row not yet touched needed two taps to open.
    const later = (fn) => setTimeout(fn, 160)
    if (!touchBound) {
      touchBound = true
      document.addEventListener("touchend", (e) => {
        if (touched && !(e.target.closest && e.target.closest("[data-touched]"))) later(untouch)
      }, {passive: true})
    }
    this.el.addEventListener("touchend", () => {
      const el = this.el
      later(() => {
        if (touched && touched !== el) untouch()
        touched = el
        el.setAttribute("data-touched", "")
      })
    }, {passive: true})
    this.el.querySelector("[data-row-prev]")?.addEventListener("click", () => this.step(-1))
    this.el.querySelector("[data-row-next]")?.addEventListener("click", () => this.next())
    this.sync = () => {
      const s = this.scroller
      if (!s) return
      const end = s.scrollLeft + s.clientWidth >= s.scrollWidth - 2
      this.el.dataset.start = String(s.scrollLeft <= 2)
      // At the end of what is drawn there may still be more to draw: only then is it the end.
      this.el.dataset.end = String(end && !this.more())
      this.near()
    }
    this.scroller?.addEventListener("scroll", this.sync, {passive: true})
    window.addEventListener("resize", this.sync)
    // Where it was scrolled to, kept for this tab: coming back to the page, each row is where it
    // was left. Saved a moment after scrolling stops; put back once there is enough drawn to reach it.
    this.placeKey = `roki:row:${location.pathname}:${this.el.id}`
    this.scroller?.addEventListener("scroll", () => {
      clearTimeout(this.saveTimer)
      this.saveTimer = setTimeout(() => {
        try { sessionStorage.setItem(this.placeKey, String(Math.round(this.scroller.scrollLeft))) } catch {}
      }, 200)
    }, {passive: true})
    this.restorePlace()
    this.sync()
    this.cards()
  },

  // The page re-renders as posters arrive: the attributes set here are the first to go.
  updated() {
    this.scroller = this.el.querySelector("[data-row-scroller]")
    // A patch drops attributes the server did not send, this one with them.
    if (touched === this.el) this.el.setAttribute("data-touched", "")
    this.restorePlace()
    this.asked = false
    this.sync()
    this.keepOpen()
  },

  restorePlace() {
    if (this.restored || !this.scroller) return
    let x = 0
    try { x = Number(sessionStorage.getItem(this.placeKey)) || 0 } catch {}
    if (x <= 0) { this.restored = true; return }
    const s = this.scroller
    if (s.scrollWidth - s.clientWidth < x - 4) return // not yet drawn that far
    s.scrollTo({left: x, behavior: "instant"}) // not the row's own smooth scrolling
    this.restored = true
  },

  // A row that draws what is in view and the rest on demand (`data-more`): there is more to ask for.
  more() {
    return this.el.dataset.more === "true"
  },

  // Close to the end of what is drawn: ask the page for the next of it, once until it has come.
  near() {
    const s = this.scroller
    if (!s || !this.more() || this.asked) return
    if (s.scrollWidth - (s.scrollLeft + s.clientWidth) < s.clientWidth * 0.6) this.ask()
  },

  ask(then) {
    this.asked = true
    this.pushEvent("row_more", {kind: this.el.dataset.kind}, () => {
      // The reply comes with the new tiles; let them be laid out before moving over them.
      if (then) setTimeout(then, 90)
    })
  },

  next() {
    const s = this.scroller
    if (s && this.more() && !this.asked && s.scrollWidth - (s.scrollLeft + s.clientWidth) < s.clientWidth * 1.6) {
      this.step(1)
      this.ask(() => this.step(1))
    } else {
      this.step(1)
    }
  },

  destroyed() {
    if (touched === this.el) touched = null
    clearTimeout(this.settleTimer)
    clearTimeout(this.saveTimer)
    window.removeEventListener("resize", this.sync)
    if (this.onHide) document.removeEventListener("visibilitychange", this.onHide)
    this.close()
    clearTimeout(this.panelTimer)
    this.panelEl?.remove()
  },

  step(dir) {
    const s = this.scroller
    if (!s) return
    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
    s.scrollBy({left: dir * Math.max(240, s.clientWidth * 0.85), behavior: reduced ? "auto" : "smooth"})
  },
}

// What opens over a poster, shared with the grids (`GridCards`): both hooks carry these.
export const cardMethods = {
  // ── the cards ──────────────────────────────────────────────────────

  cards() {
    // A pointer that hovers, on a screen with room for a card that opens.
    // Any width: only a pointer that hovers decides. Checked on each move (not once here), so a
    // window resized, or a device changed, never leaves the hooks half on.
    if (!this.scroller) return
    const hovers = matchMedia("(hover: hover)")
    this.hot = null
    // The tab hidden (another tab, the window minimised): the card closes, and its trailer with
    // it — nothing plays unseen. The pointer resting on the poster opens it again on return.
    this.onHide = () => { if (document.hidden) this.leave() }
    document.addEventListener("visibilitychange", this.onHide)

    // A poster opens only when the pointer has come to rest on it: one passed over on the way to a
    // chevron, or across the row, opens nothing. Every move more than a few pixels starts the wait
    // again; leaving the poster closes it (or cancels the wait).
    this.scroller.addEventListener("mousemove", (e) => {
      const li = e.target.closest?.("[data-card]")
      if (!hovers.matches || !li || li.hasAttribute("data-no-card") || this.atEdge(e.clientX)) { this.leave(); return }
      if (li === this.hot) return
      // The first move seen only says where the pointer is: a page that opens under a pointer that
      // has not moved (the browser reports a move when content changes under it) must not open a
      // card at once — the title page did, the moment it appeared, under the poster just clicked.
      if (!this.at) { this.at = {x: e.clientX, y: e.clientY}; return }
      const moved = Math.hypot(e.clientX - this.at.x, e.clientY - this.at.y) > STILL_PX
      if (li !== this.cand || moved) {
        this.at = {x: e.clientX, y: e.clientY}
        this.cand = li
        clearTimeout(this.stillTimer)
        this.stillTimer = setTimeout(() => { if (this.cand === li) this.open(li) }, STILL_MS)
      }
    })
    this.scroller.addEventListener("mouseout", (e) => {
      const to = e.relatedTarget
      if ((this.hot && !this.hot.contains(to)) || (this.cand && !this.cand.contains(to))) this.leave()
    })
    // The glow under the pointer is in the poster's own colour, read the moment it is reached.
    const reach = (e) => { const li = e.target.closest?.("[data-card]"); if (li) tint(li) }
    this.scroller.addEventListener("mouseover", reach)
    this.scroller.addEventListener("focusin", reach)
    this.scroller.addEventListener("click", (e) => {
      const save = e.target.closest?.("[data-card-save]")
      if (save) { e.preventDefault(); this.toggle(save.closest("[data-card]"), "saved"); return }
      const seen = e.target.closest?.("[data-card-watched]")
      if (seen) { e.preventDefault(); this.toggle(seen.closest("[data-card]"), "watched") }
    })
  },

  // In the strip along a side where a chevron is shown (and a little beyond it), going for the
  // chevron: a card opening here, and the other posters stepping back for it, only to close again
  // as the pointer reaches the chevron, was a flicker. Nothing opens there.
  atEdge(x) {
    const box = this.scroller.getBoundingClientRect()
    const REACH = 96
    return (this.el.dataset.start === "false" && x - box.left < REACH) ||
      (this.el.dataset.end === "false" && box.right - x < REACH)
  },

  // A page patch (posters arriving, a season's picture swapped in) redraws the tile and drops what
  // was set on it here; the card is still the one the pointer is on, so it is opened again as it was.
  // The card, one for this row or grid: the page's template (`card_template` in posters.ex)
  // cloned on first use and placed — over the whole slot in a row, over the middle of the cell in
  // a grid. It lives in whichever poster is open; every poster once carried one of its own,
  // hidden, which was more than half of the home page's elements.
  panel() {
    if (this.panelEl) return this.panelEl
    const tpl = document.getElementById("card-template")
    if (!tpl) return null
    const el = tpl.content.firstElementChild.cloneNode(true)
    const inner = el.querySelector("[data-card-inner]")
    if (this.grid) el.classList.add("inset-y-0", "left-1/2", "w-[170%]", "[translate:-50%_0]")
    else { el.classList.add("inset-0"); inner?.classList.add("w-[calc(var(--card-w)*1.7)]") }
    const slot = el.querySelector("[data-card-trailer]")
    if (slot) slot.id = `card-trailer-${this.el.id || "cards"}`
    return (this.panelEl = el)
  },

  // The card filled for this poster (from its data attributes) and put into it.
  mount(li) {
    const p = this.panel()
    if (!p) return
    clearTimeout(this.panelTimer)
    const d = li.dataset
    const set = (sel, text) => { const el = p.querySelector(sel); if (el) el.textContent = text || "" }
    set("[data-card-title]", d.title)
    set("[data-card-vote]", d.vote ? `★ ${d.vote}` : "")
    set("[data-card-year]", d.year)
    set("[data-card-runtime]", ""); set("[data-card-overview]", ""); set("[data-card-genres]", "")
    for (const a of p.querySelectorAll("[data-card-title-link], [data-card-more]")) a.href = d.titleHref || "#"
    const play = p.querySelector("[data-card-play]")
    if (play) { play.href = d.playHref || d.titleHref || "#"; play.setAttribute("aria-label", `Play ${d.title || ""}`) }
    p.querySelector("[data-card-more]")?.setAttribute("aria-label", `More about ${d.title || ""}`)
    const signed = d.signed === "true"
    for (const el of p.querySelectorAll("[data-signed-only]")) el.style.display = signed ? "" : "none"
    for (const el of p.querySelectorAll("[data-guest-only]")) el.style.display = signed ? "none" : ""
    const watched = p.querySelector("[data-card-watched]")
    if (watched) { const l = (d.key || "").startsWith("tv/") ? "Mark as completed" : "Mark as watched"; watched.setAttribute("aria-label", l); watched.title = l }
    const img = p.querySelector("[data-card-img]")
    if (img) {
      delete img.dataset.loaded
      img.classList.add("blur-sm", "scale-110")
      if (d.srcset) { img.srcset = d.srcset; img.sizes = "(min-width: 1024px) 24rem, 100vw" }
      else { img.removeAttribute("srcset"); img.removeAttribute("sizes") }
      if (d.picture) img.src = d.picture; else img.removeAttribute("src")
    }
    // Into the poster's box where it has one (a grid cell's inner box is what is `relative`),
    // else the poster itself.
    this.panelHost = li.querySelector("[data-card-box]") || li
    this.panelHost.appendChild(p)
    // Laid out once before the poster is marked open, so the card fades in from nothing instead
    // of appearing at once (a transition needs a starting style to run from).
    void p.offsetWidth
    setSaved(li, false)
    setWatched(li, false)
  },

  keepOpen() {
    const li = this.hot
    if (!li) return
    if (!li.isConnected) { this.hot = null; return }
    // A patch of the poster drops the card (the server never sent it): back in.
    if (this.panelEl && !li.contains(this.panelEl)) (li.querySelector("[data-card-box]") || li).appendChild(this.panelEl)
    if (li.dataset.open === "true") return
    li.dataset.open = "true"
    if (this.grid) {
      const r = li.getBoundingClientRect()
      const extra = r.width * 0.35 + 12
      li.dataset.edge = r.left < extra ? "left" : r.right > innerWidth - extra ? "right" : ""
      this.nudge(li)
    }
  },

  leave() {
    clearTimeout(this.stillTimer)
    this.cand = null
    this.at = null
    this.close()
  },

  open(li) {
    this.close()
    this.hot = li
    if (this.grid) {
      // A card of 1.7 poster-widths opens around the middle of its cell: at the grid's edge it opens
      // towards the middle instead, so it never leaves the window.
      const r = li.getBoundingClientRect()
      const extra = r.width * 0.35 + 12
      li.dataset.edge = r.left < extra ? "left" : r.right > innerWidth - extra ? "right" : ""
    }
    if (!this.grid) this.slideFor(li)
    this.sweep(li)
    this.mount(li)
    li.dataset.open = "true"
    this.timers = []
    this.nudge(li)
    this.show(li, Date.now())
  },

  // The dimming of the others spreads out from the card: each poster waits in proportion to how
  // far from the card it is (`--dim-delay`, read by the filter transition in app.css), so the
  // neighbours go first and the sides of the row last. Lifting goes the same way, out from the
  // card. The delays stay on the posters for the lift. (It once swept in from the sides, while the
  // chevrons' shade still greyed the posters under them.) A grid does not sweep: the whole page
  // goes down and comes back up at once — rippling out and back from every poster the pointer
  // crosses was too much movement on a page that is nothing but posters.
  sweep(li) {
    const SWEEP = 0.22 // s, from the nearest poster to the farthest
    if (this.grid) {
      for (const c of this.scroller.querySelectorAll("[data-grid-card]")) c.style.removeProperty("--dim-delay")
      return
    }
    const sel = ":scope > [data-card]"
    const r = li.getBoundingClientRect()
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2
    // Only what is on the screen counts: the row goes on well past its sides, and measured against
    // those the posters at the sides would wait nearly as long as the card's neighbours.
    const cards = [...this.scroller.querySelectorAll(sel)].filter((c) => c !== li).map((c) => {
      const b = c.getBoundingClientRect()
      const seen = b.right > 0 && b.left < innerWidth && b.bottom > 0 && b.top < innerHeight
      return {c, seen, d: Math.hypot(b.left + b.width / 2 - cx, b.top + b.height / 2 - cy)}
    })
    const far = Math.max(1, ...cards.filter((x) => x.seen).map((x) => x.d))
    for (const {c, seen, d} of cards) c.style.setProperty("--dim-delay", seen ? `${(Math.min(1, d / far) * SWEEP).toFixed(3)}s` : "0s")
    li.style.removeProperty("--dim-delay")
  },

  // How far the row slides left as a card opens in it. Usually the card grows evenly to both sides
  // (0.35 of a poster each); near a chevron it is the distance that keeps the whole card clear of
  // the chevron's strip, worked out before it opens: the card is then in its place from the start
  // and nothing moves again afterwards (it used to be scrolled into view once open, a second jerk).
  slideFor(li) {
    const box = this.scroller.getBoundingClientRect()
    const r = li.getBoundingClientRect()
    const grow = r.width * 0.7
    const hasLeft = this.el.dataset.start === "false"
    const hasRight = this.el.dataset.end === "false"
    const minLeft = box.left + (hasLeft ? 60 : 12)
    const maxRight = box.right - (hasRight ? 60 : 12)
    let slide = r.width * 0.35
    const overRight = r.right + grow - slide - maxRight
    if (overRight > 0) slide += overRight
    const overLeft = minLeft - (r.left - slide)
    if (overLeft > 0) slide -= overLeft
    this.scroller.style.setProperty("--slide", `${Math.max(0, slide)}px`)
  },

  // In a grid the card opens over its cell and the others stay where they are in the flow: the ones
  // in its row are only moved aside a little (a translate, nothing reflows) so the card has room.
  nudge(li) {
    if (!this.grid || this.hot !== li) return
    const r = li.getBoundingClientRect()
    const wide = r.width * 0.7
    const edge = li.dataset.edge
    const left = edge === "left" ? 0 : edge === "right" ? wide : wide / 2
    const right = edge === "right" ? 0 : edge === "left" ? wide : wide / 2

    // The same distance for every one on a side, so they stay evenly spaced. One at the edge may
    // slip a little off the window: the card being looked at is the one that matters.
    const row = [...this.el.querySelectorAll("[data-grid-card]")].filter(
      (c) => c !== li && Math.abs(c.getBoundingClientRect().top - r.top) <= 4
    )
    const before = row.filter((c) => c.getBoundingClientRect().left < r.left)
    const after = row.filter((c) => c.getBoundingClientRect().left >= r.left)
    const goLeft = left
    const goRight = right

    this.nudged = []
    for (const [list, shift] of [[before, -goLeft], [after, goRight]]) {
      for (const c of list) {
        c.style.setProperty("--nudge", `${shift}px`)
        c.dataset.nudge = "true"
        this.nudged.push(c)
      }
    }
  },

  async show(li, started) {
    const key = li.dataset.key
    const info = await load(key)
    if (this.hot !== li) return

    if (info) this.fill(li, info)

    if (li.dataset.signed === "true") {
      libraryState(key).then((st) => {
        if (this.hot === li && st) { setSaved(li, st.saved); setWatched(li, st.watched) }
      })
    }
    if (info?.trailer) {
      const wait = Math.max(0, TRAILER_MS - (Date.now() - started))
      this.timers.push(setTimeout(() => { if (this.hot === li) this.play(li, info.trailer) }, wait))
    }
  },

  fill(li, info) {
    const set = (sel, text) => { const el = li.querySelector(sel); if (el) el.textContent = text }
    set("[data-card-runtime]", minutes(info.minutes) || (info.seasons ? `${info.seasons} season${info.seasons > 1 ? "s" : ""}` : ""))
    set("[data-card-genres]", (info.genres || []).join(" · "))
    set("[data-card-overview]", info.overview || "")
    if (info.backdrop) {
      const img = li.querySelector("[data-card-img]")
      const next = new Image()
      // The placeholder is the poster with a srcset; the wide picture replaces both, or the
      // browser would keep drawing the poster from the set.
      next.onload = () => { if (img) { img.removeAttribute("srcset"); img.removeAttribute("sizes"); img.src = info.backdrop; img.classList.remove("blur-sm", "scale-110") } }
      next.src = info.backdrop
    }
  },

  play(li, youtubeKey) {
    const slot = li.querySelector("[data-card-trailer]")
    if (!slot || slot.querySelector("iframe")) return
    const f = document.createElement("iframe")
    f.src =
      `https://www.youtube-nocookie.com/embed/${youtubeKey}?autoplay=1&mute=1&controls=0&disablekb=1` +
      `&modestbranding=1&rel=0&playsinline=1&iv_load_policy=3&fs=0`
    f.allow = "autoplay; encrypted-media"
    f.title = "Trailer"
    f.tabIndex = -1
    // The player's own title bar (top) and controls (bottom) are inside the frame, not over the
    // video: a frame taller than the picture, shifted up by the same share, leaves them outside.
    f.className = "pointer-events-none absolute left-0 w-full border-0"
    f.style.top = "-30%"
    f.style.height = "160%"
    f.addEventListener("load", () => slot.classList.replace("opacity-0", "opacity-100"))
    slot.appendChild(f)
  },

  close() {
    (this.timers || []).forEach(clearTimeout)
    this.timers = []
    const li = this.hot
    this.hot = null
    if (li) delete li.dataset.open
    if (li && !this.grid) {
      this.scroller.style.removeProperty("--slide")
      // Snapping comes back only once the row has settled (`data-settling`, app.css): put back
      // while the card was still shrinking, the row re-snapped to a point that moved as the layout
      // did — the whole row lurched sideways and back, right as the pointer reached a chevron.
      this.scroller.setAttribute("data-settling", "")
      clearTimeout(this.settleTimer)
      this.settleTimer = setTimeout(() => { if (!this.hot) this.scroller.removeAttribute("data-settling") }, 450)
    }
    ;(this.nudged || []).forEach((c) => { delete c.dataset.nudge; c.style.removeProperty("--nudge") })
    this.nudged = []
    const slot = li?.querySelector("[data-card-trailer]")
    if (slot) {
      slot.textContent = ""
      slot.classList.replace("opacity-100", "opacity-0")
    }
    // The card leaves the poster once it has faded (0.2 s); opening another takes it at once.
    const p = this.panelEl
    if (p && li) {
      clearTimeout(this.panelTimer)
      this.panelTimer = setTimeout(() => { if (this.hot !== li && li.contains(p)) p.remove() }, 300)
    }
  },

  // Save for later, or mark watched: the server answers with where the title stands for this account,
  // and both buttons are drawn from that.
  async toggle(li, what) {
    if (!li) return
    try {
      const res = await fetch(`/library/${li.dataset.key}/${what}`, {
        method: "POST",
        credentials: "same-origin",
        headers: {"x-csrf-token": csrf(), accept: "application/json"},
      })
      if (res.ok) {
        const st = await res.json()
        setSaved(li, st.saved)
        setWatched(li, st.watched)
        // On the Saved list, taking a title off drops its tile (a hidden button the page listens to).
        if (what === "saved" && !st.saved) li.querySelector("[phx-click=unsave]")?.click()
      }
    } catch (_e) {
      // the buttons stay as they were
    }
  },
}

Object.assign(ShelfRow, cardMethods)
