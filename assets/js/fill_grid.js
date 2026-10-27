// Keeps a poster grid to whole rows while there is more to load. A page of titles is a fixed
// number, the number of columns depends on the window and the grid size, so the last row is
// usually part-empty; that row waits (hidden) until the next page completes it. When there is
// nothing more to load, everything is shown.
export function visibleCount(total, columns, more) {
  if (!more || columns < 1 || total < columns) return total
  return total - (total % columns)
}

function columnsOf(el) {
  const cols = getComputedStyle(el).gridTemplateColumns
  return cols && cols !== "none" ? cols.split(" ").length : 1
}

// Where the reader was on a grid, per address: how many pages were loaded and how far down the
// window was scrolled. Coming back with the back button, the page is told (join params, `place`)
// and loads all of those pages at once, so the first thing drawn is the full list; this hook then
// scrolls to the saved spot. Only history navigation restores it — opening the page afresh
// starts at the top.
const placeKey = () => `roki:place:${location.pathname}${location.search}`

function readPlace() {
  try {
    return JSON.parse(sessionStorage.getItem(placeKey()) || "null")
  } catch (_e) {
    return null
  }
}

function writePlace(place) {
  try {
    sessionStorage.setItem(placeKey(), JSON.stringify(place))
  } catch (_e) {
    // storage blocked: the grid just starts over, as it always did
  }
}

// The saved place for this address, when the reader got here with back/forward or a reload
// (popstate just fired, or the document itself was just loaded that way); else nothing.
export function placeParam() {
  const popped = window.__rokiPopAt && Date.now() - window.__rokiPopAt < 5000
  const nav = performance.getEntriesByType && performance.getEntriesByType("navigation")[0]
  const reloaded =
    !!nav && (nav.type === "back_forward" || nav.type === "reload") && performance.now() < 8000
  const place = popped || reloaded ? readPlace() : null
  return place && Number.isFinite(place.pages) && Number.isFinite(place.y) ? place : null
}

// The same, for a list that is not one grid (the watched page: months, each its own grid). It
// only remembers and restores the place; the server loads as many pages as were open
// (`data-page`) and says where to scroll (`data-restore-y`).
export const KeepPlace = {
  mounted() {
    this.onScroll = () => {
      if (this.restoring) return
      clearTimeout(this.saveTimer)
      this.saveTimer = setTimeout(
        () => writePlace({y: window.scrollY, pages: Number(this.el.dataset.page) || 1}),
        150,
      )
    }
    window.addEventListener("scroll", this.onScroll, {passive: true})
    this.restore()
  },

  updated() {
    this.restore()
  },

  destroyed() {
    window.removeEventListener("scroll", this.onScroll)
    clearTimeout(this.saveTimer)
  },

  restore() {
    const y = this.el.dataset.restoreY
    if (y === undefined || y === "" || !Number.isFinite(Number(y))) return
    this.restoring = true
    requestAnimationFrame(() => {
      window.scrollTo(0, Number(y))
      this.restoring = false
      this.pushEvent("placed", {})
    })
  },
}

export const FillGrid = {
  mounted() {
    this.onResize = () => {
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.fill(), 120)
    }
    window.addEventListener("resize", this.onResize)
    this.fill()

    // Saved on scroll, once it settles. A scroll to the top caused by leaving the page
    // arrives after destroyed() has cleared this, so it never overwrites the real place.
    this.onScroll = () => {
      if (this.restoring) return
      clearTimeout(this.saveTimer)
      this.saveTimer = setTimeout(
        () => writePlace({y: window.scrollY, pages: Number(this.el.dataset.page) || 1}),
        150,
      )
    }
    window.addEventListener("scroll", this.onScroll, {passive: true})

    const y = this.el.dataset.restoreY
    if (y !== undefined && y !== "" && Number.isFinite(Number(y))) {
      this.restoring = true
      requestAnimationFrame(() => {
        window.scrollTo(0, Number(y))
        this.restoring = false
        this.pushEvent("placed", {})
      })
    }
  },

  updated() {
    this.fill()
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("scroll", this.onScroll)
    clearTimeout(this.timer)
    clearTimeout(this.saveTimer)
  },

  fill() {
    const items = [...this.el.children]
    const more = this.el.dataset.more === "true"
    const show = visibleCount(items.length, columnsOf(this.el), more)
    items.forEach((li, i) => li.classList.toggle("hidden", i >= show))
  },
}
