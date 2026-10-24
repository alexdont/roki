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
// window was scrolled. Coming back to a grid with the back button loads those pages again and
// scrolls to the same spot, instead of starting over at the first page. Only history navigation
// restores it — opening the page afresh starts at the top.
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

// The first mount of a document that was reloaded or reached with back/forward.
let firstMount = true
function arrivedByHistory() {
  const popped = window.__rokiPopAt && Date.now() - window.__rokiPopAt < 5000
  let reloaded = false
  if (firstMount) {
    const nav = performance.getEntriesByType && performance.getEntriesByType("navigation")[0]
    reloaded = !!nav && (nav.type === "back_forward" || nav.type === "reload")
  }
  firstMount = false
  window.__rokiPopAt = 0
  return popped || reloaded
}

export const FillGrid = {
  mounted() {
    this.onResize = () => {
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.fill(), 120)
    }
    window.addEventListener("resize", this.onResize)

    this.target = arrivedByHistory() ? readPlace() : null
    if (this.target && !(this.target.pages > 1 || this.target.y > 0)) this.target = null

    // Saved on scroll, once it settles. A scroll to the top caused by leaving the page
    // arrives after destroyed() has cleared this, so it never overwrites the real place.
    this.onScroll = () => {
      if (this.target) return
      clearTimeout(this.saveTimer)
      this.saveTimer = setTimeout(
        () => writePlace({y: window.scrollY, pages: Number(this.el.dataset.page) || 1}),
        150,
      )
    }
    window.addEventListener("scroll", this.onScroll, {passive: true})

    this.fill()
    this.restore()
  },

  updated() {
    this.fill()
    this.restore()
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("scroll", this.onScroll)
    clearTimeout(this.timer)
    clearTimeout(this.saveTimer)
  },

  // Load pages until the saved number is there, then scroll to where the reader was.
  restore() {
    if (!this.target) return
    const page = Number(this.el.dataset.page) || 0
    const more = this.el.dataset.more === "true"

    if (page < this.target.pages && more) {
      const button = document.querySelector('button[phx-click="more"]')
      if (button && !button.disabled && this.asked !== page) {
        this.asked = page
        button.click()
      }
      return
    }

    const y = this.target.y
    this.target = null
    requestAnimationFrame(() => window.scrollTo(0, y))
  },

  fill() {
    const items = [...this.el.children]
    const more = this.el.dataset.more === "true"
    const show = visibleCount(items.length, columnsOf(this.el), more)
    items.forEach((li, i) => li.classList.toggle("hidden", i >= show))
  },
}
