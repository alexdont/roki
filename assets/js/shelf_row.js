// A row of posters that scrolls sideways (the home page, on a wide screen). The chevrons are
// the row's own: they show on hover (CSS) and this keeps `data-start` / `data-end` true to where
// the row is scrolled, so the left one only shows once there is something to go back to and the
// right one goes when there is nothing further.
export const ShelfRow = {
  mounted() {
    this.scroller = this.el.querySelector("[data-row-scroller]")
    this.el.querySelector("[data-row-prev]")?.addEventListener("click", () => this.step(-1))
    this.el.querySelector("[data-row-next]")?.addEventListener("click", () => this.step(1))
    this.sync = () => {
      const s = this.scroller
      if (!s) return
      this.el.dataset.start = String(s.scrollLeft <= 2)
      this.el.dataset.end = String(s.scrollLeft + s.clientWidth >= s.scrollWidth - 2)
    }
    this.scroller?.addEventListener("scroll", this.sync, {passive: true})
    window.addEventListener("resize", this.sync)
    this.sync()
  },

  // The page re-renders as posters arrive: the attributes set here are the first to go.
  updated() {
    this.scroller = this.el.querySelector("[data-row-scroller]")
    this.sync()
  },

  destroyed() {
    window.removeEventListener("resize", this.sync)
  },

  step(dir) {
    const s = this.scroller
    if (!s) return
    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
    s.scrollBy({left: dir * Math.max(240, s.clientWidth * 0.85), behavior: reduced ? "auto" : "smooth"})
  },
}
