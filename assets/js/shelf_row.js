// A row of posters that scrolls sideways (the home page, on a wide screen).
//
// The chevrons are the row's own: they show on hover (CSS) and this keeps `data-start` /
// `data-end` true to where the row is scrolled, so the left one only shows once there is something
// to go back to and the right one goes when there is nothing further.
//
// The cards: rest the pointer on a poster and it opens into a wider card (CSS does the opening;
// the neighbours make way as flex items). Once it is open this fetches what the card shows that
// the page did not carry — length, genres, the wide picture, the trailer — and, a moment after it
// opened, swaps the picture for the trailer playing muted. Leaving the card stops it.
const cache = new Map()
const OPEN_MS = 320 // the card's CSS delay before it starts to open
const TRAILER_MS = 1500 // how long the picture is shown before the trailer replaces it

const csrf = () => document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""

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
  const btn = li.querySelector("[data-card-save]")
  if (!btn) return
  btn.querySelector("[data-off]")?.classList.toggle("hidden", !!saved)
  btn.querySelector("[data-on]")?.classList.toggle("hidden", !saved)
  btn.setAttribute("aria-label", saved ? "Saved for later (click to remove)" : "Save for later")
  btn.title = btn.getAttribute("aria-label")
}

export const ShelfRow = {
  mounted() {
    this.scroller = this.el.querySelector("[data-row-scroller]")
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
    this.sync()
    this.cards()
  },

  // The page re-renders as posters arrive: the attributes set here are the first to go.
  updated() {
    this.scroller = this.el.querySelector("[data-row-scroller]")
    this.asked = false
    this.sync()
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
    window.removeEventListener("resize", this.sync)
    this.close()
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
    if (!this.scroller || !matchMedia("(hover: hover) and (min-width: 1024px)").matches) return
    this.hot = null

    this.scroller.addEventListener("mouseover", (e) => {
      const li = e.target.closest?.("[data-card]")
      if (li && li !== this.hot) this.open(li)
    })
    this.scroller.addEventListener("mouseout", (e) => {
      if (this.hot && !this.hot.contains(e.relatedTarget)) this.close()
    })
    this.scroller.addEventListener("click", (e) => {
      const btn = e.target.closest?.("[data-card-save]")
      if (btn) { e.preventDefault(); this.toggleSaved(btn.closest("[data-card]")) }
    })
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
    const started = Date.now()
    this.timers = [setTimeout(() => { this.nudge(li); this.show(li, started) }, OPEN_MS)]
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
    this.timers.push(setTimeout(() => this.reveal(li), 380))

    if (li.dataset.signed === "true") {
      libraryState(key).then((st) => { if (this.hot === li && st) setSaved(li, st.saved) })
    }
    if (info?.trailer) {
      const wait = Math.max(0, TRAILER_MS - (Date.now() - started - OPEN_MS))
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
      next.onload = () => { if (img) { img.src = info.backdrop; img.classList.remove("blur-sm", "scale-110") } }
      next.src = info.backdrop
    }
  },

  // A card that opened at the edge of the row is brought fully into view.
  reveal(li) {
    if (this.hot !== li || this.grid) return
    const r = li.getBoundingClientRect()
    const box = this.scroller.getBoundingClientRect()
    if (r.right > box.right - 16) {
      this.scroller.scrollBy({left: r.right - box.right + 56, behavior: "smooth"})
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
    ;(this.nudged || []).forEach((c) => { delete c.dataset.nudge; c.style.removeProperty("--nudge") })
    this.nudged = []
    const slot = li?.querySelector("[data-card-trailer]")
    if (slot) {
      slot.textContent = ""
      slot.classList.replace("opacity-100", "opacity-0")
    }
  },

  async toggleSaved(li) {
    if (!li) return
    try {
      const res = await fetch(`/library/${li.dataset.key}/saved`, {
        method: "POST",
        credentials: "same-origin",
        headers: {"x-csrf-token": csrf(), accept: "application/json"},
      })
      if (res.ok) {
        const saved = (await res.json()).saved
        setSaved(li, saved)
        // On the Saved list, taking a title off drops its tile (a hidden button the page listens to).
        if (!saved) li.querySelector("[phx-click=unsave]")?.click()
      }
    } catch (_e) {
      // the button stays as it was
    }
  },
}

Object.assign(ShelfRow, cardMethods)
