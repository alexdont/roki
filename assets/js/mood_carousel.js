// The mood picker on the home page: one slide at a time, turning every `data-every` ms. Hovering
// (or focusing) a mood shows it and holds it; leaving lets the turning go on. The chip of the
// shown mood is lit and carries a thin bar that fills as its turn runs. Only one slide is visible
// at a time, so hidden slides' lazy images are not fetched until they are shown.
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
    this.el.addEventListener("mouseenter", () => { this.held = true; this.freeze() })
    this.el.addEventListener("mouseleave", () => { this.held = false; this.arm() })
    this.onVisibility = () => { this.visible = !document.hidden; this.visible ? this.arm() : this.freeze() }
    document.addEventListener("visibilitychange", this.onVisibility)

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
  },

  destroyed() {
    clearTimeout(this.timer)
    document.removeEventListener("visibilitychange", this.onVisibility)
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
    this.chips.forEach((c, k) => {
      const on = k === i
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
    // On a phone the chips scroll sideways: keep the lit one in view.
    const chip = this.chips[i]
    if (chip && chip.scrollIntoView && window.innerWidth < 640) chip.scrollIntoView({block: "nearest", inline: "center", behavior: "smooth"})
  },

  arm() {
    clearTimeout(this.timer)
    if (this.held || !this.visible || this.reduced) return
    this.show(this.index)
    this.timer = setTimeout(() => { this.show((this.index + 1) % this.slides.length); this.arm() }, this.every)
  },

  freeze() {
    clearTimeout(this.timer)
    const bar = this.chips[this.index] && this.chips[this.index].querySelector("[data-mood-bar]")
    if (bar) { const w = getComputedStyle(bar).transform; bar.style.transition = "none"; bar.style.transform = w === "none" ? "scaleX(0)" : w }
  },
}
