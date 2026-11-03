// The mood picker on the home page: one slide at a time, turning every `data-every` ms. Hovering
// (or focusing) a mood shows it and holds it; leaving lets the turning go on. The chip of the
// shown mood is lit and carries a thin bar that fills as its turn runs. Only one slide is visible
// at a time, so hidden slides' lazy images are not fetched until they are shown.
//
// A chip is a link to the mood's page, and what pressing it does depends on the device. With a
// mouse it opens the page: you have already seen the mood by hovering over it. On a touch screen
// there is no hovering, so the press is the only way to look, and it shows the mood in the
// carousel instead — the page is opened by the "Show me" button inside the slide.
export const MoodCarousel = {
  mounted() {
    this.every = Number(this.el.dataset.every) || 6000
    this.slides = [...this.el.querySelectorAll("[data-mood]")]
    this.chips = [...this.el.querySelectorAll("[data-mood-chip]")]
    this.order = this.slides.map((s) => s.dataset.mood)
    this.index = 0
    this.held = false
    this.visible = !document.hidden

    this.chips.forEach((chip) => {
      const show = () => { this.held = true; this.go(chip.dataset.moodChip) }
      chip.addEventListener("mouseenter", show)
      chip.addEventListener("focus", show)
      chip.addEventListener("mouseleave", () => { this.held = false; this.arm() })
      chip.addEventListener("blur", () => { this.held = false; this.arm() })
    })
    // Delegated, so it keeps working when the page re-renders the chips.
    this.el.addEventListener("click", (e) => {
      const chip = e.target.closest && e.target.closest("[data-mood-chip]")
      if (!chip || !this.el.contains(chip) || !this.touchOnly()) return

      // Not the page: the mood. A press with a modifier is left alone, as it is anywhere.
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return
      e.preventDefault()
      e.stopPropagation()
      // The emulated hover that comes before a tap holds the carousel; a tap is a choice, not a
      // finger resting on it, so the turning goes on from the mood chosen.
      this.held = false
      this.go(chip.dataset.moodChip)
      this.arm()
    }, true)
    // The chevrons step through the moods; like a tap on a chip, a press is a choice, so the
    // turning goes on from the mood chosen.
    this.el.addEventListener("click", (e) => {
      const b = e.target.closest && e.target.closest("[data-mood-prev],[data-mood-next]")
      if (!b || !this.el.contains(b)) return
      const n = this.slides.length
      const step = b.hasAttribute("data-mood-next") ? 1 : -1
      this.show((this.index + step + n) % n)
      this.arm()
    })
    this.el.addEventListener("mouseenter", () => { this.held = true; this.freeze() })
    this.el.addEventListener("mouseleave", () => { this.held = false; this.arm() })
    this.onVisibility = () => { this.visible = !document.hidden; this.visible ? this.arm() : this.freeze() }
    document.addEventListener("visibilitychange", this.onVisibility)

    // The row of moods slides down out of the picture as the page is scrolled from the top, following
    // the scroll itself (one frame at a time), and comes back up with it.
    this.onScroll = () => {
      if (this.scrollFrame) return
      this.scrollFrame = requestAnimationFrame(() => { this.scrollFrame = null; this.tuck() })
    }
    window.addEventListener("scroll", this.onScroll, {passive: true})
    this.tuck()

    // A touch screen: a touch brings the row of moods into focus (app.css, `data-touched`) until a
    // few seconds after the last one, and a sideways swipe turns to the next or previous mood.
    let start = null
    const touched = () => {
      this.el.dataset.touched = ""
      clearTimeout(this.untouch)
      this.untouch = setTimeout(() => { delete this.el.dataset.touched }, 4000)
    }
    this.el.addEventListener("touchstart", (e) => {
      touched()
      const t = e.touches[0]
      // The row of moods scrolls sideways itself: a swipe there moves the row, not the mood.
      const onRow = e.target.closest && e.target.closest("[data-mood-tabs]")
      start = t && !onRow ? {x: t.clientX, y: t.clientY} : null
    }, {passive: true})
    this.el.addEventListener("touchend", (e) => {
      touched()
      const t = e.changedTouches[0]
      if (!start || !t) return
      const dx = t.clientX - start.x, dy = t.clientY - start.y
      start = null
      // Sideways and far enough to mean it; a scroll of the page is up and down.
      if (Math.abs(dx) < 45 || Math.abs(dx) < Math.abs(dy) * 1.5) return
      const n = this.slides.length
      this.held = false
      this.show((this.index + (dx < 0 ? 1 : -1) + n) % n)
      this.arm()
    }, {passive: true})

    this.reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
    this.show(0)
    this.arm()
  },

  // The slides are re-rendered as the moods' titles arrive: pick the new elements up and show
  // the same mood as before.
  updated() {
    this.slides = [...this.el.querySelectorAll("[data-mood]")]
    this.chips = [...this.el.querySelectorAll("[data-mood-chip]")]
    this.order = this.slides.map((s) => s.dataset.mood)
    this.show(Math.min(this.index, this.slides.length - 1))
    // A patch drops the style the hook set on the row.
    this.tuck()
  },

  destroyed() {
    clearTimeout(this.timer)
    clearTimeout(this.untouch)
    cancelAnimationFrame(this.scrollFrame)
    window.removeEventListener("scroll", this.onScroll)
    document.removeEventListener("visibilitychange", this.onVisibility)
  },

  // Two numbers from the scroll, for app.css: how far the row of moods has dissolved (`--tuck`, 0 at
  // the top of the page, 1 once about half the carousel is scrolled past) and how far the carousel
  // itself has gone by (`--depth`, over its whole height) for the posters and words to drift. Both
  // linear, at the pace of the scroll.
  tuck() {
    const h = this.el.offsetHeight || 1
    const y = Math.max(0, window.scrollY)
    this.el.style.setProperty("--depth", Math.min(1, y / h).toFixed(3))
    const row = this.el.querySelector("[data-mood-tabs]")
    if (!row) return
    const x = Math.min(1, y / Math.max(220, h * 0.5))
    row.style.setProperty("--tuck", x.toFixed(3))
    row.style.pointerEvents = x > 0.6 ? "none" : ""
  },

  // A device that cannot hover — a phone or a tablet, whatever the width of its screen.
  touchOnly() {
    return matchMedia("(hover: none)").matches
  },

  go(slug) {
    const i = this.order.indexOf(slug)
    if (i >= 0) this.show(i)
  },

  show(i) {
    this.index = i
    this.slides.forEach((s, k) => {
      const on = k === i
      s.classList.toggle("opacity-0", !on)
      s.classList.toggle("pointer-events-none", !on)
      if (on && !s.classList.contains("is-active")) s.classList.add("is-active")
      if (!on) s.classList.remove("is-active")
      s.setAttribute("aria-hidden", String(!on))
      if (on) s.querySelectorAll('img[loading="lazy"]').forEach((img) => { img.loading = "eager" })
    })
    const slug = this.order[i]
    this.chips.forEach((c) => {
      const on = c.dataset.moodChip === slug
      c.setAttribute("aria-selected", String(on))
      const bar = c.querySelector("[data-mood-bar]")
      if (!bar) return
      bar.style.transition = "none"
      bar.style.transform = "scaleX(0)"
      if (on && !this.held && !this.reduced) {
        // Restart the fill from zero for this turn.
        void bar.offsetWidth
        bar.style.transition = `transform ${this.every}ms linear`
        bar.style.transform = "scaleX(1)"
      }
    })
    this.centre(this.chips.find((c) => c.dataset.moodChip === slug))
  },

  // On a phone the chips scroll sideways: keep the lit one in the middle of its row.
  //
  // Sideways only, and by scrolling the row itself. `scrollIntoView` scrolls every ancestor that
  // can scroll, the page included, and a mood turns on a timer: anyone reading further down the
  // page was carried back up to the picker every six seconds, and again each time the page
  // updated.
  centre(chip) {
    const row = chip && chip.parentElement
    if (!row || window.innerWidth >= 1024 || row.scrollWidth <= row.clientWidth) return

    const here = chip.getBoundingClientRect()
    const box = row.getBoundingClientRect()
    const left = row.scrollLeft + (here.left - box.left) - (box.width - here.width) / 2
    row.scrollTo({left: Math.max(0, left), behavior: this.reduced ? "auto" : "smooth"})
  },

  arm() {
    clearTimeout(this.timer)
    if (this.held || !this.visible || this.reduced) return
    this.show(this.index)
    this.timer = setTimeout(() => { this.show((this.index + 1) % this.slides.length); this.arm() }, this.every)
  },

  freeze() {
    clearTimeout(this.timer)
    const slug = this.order[this.index]
    this.chips.filter((c) => c.dataset.moodChip === slug).forEach((c) => {
      const bar = c.querySelector("[data-mood-bar]")
      if (bar) { const w = getComputedStyle(bar).transform; bar.style.transition = "none"; bar.style.transform = w === "none" ? "scaleX(0)" : w }
    })
  },
}
