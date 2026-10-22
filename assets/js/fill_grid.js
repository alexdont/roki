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

export const FillGrid = {
  mounted() {
    this.onResize = () => {
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.fill(), 120)
    }
    window.addEventListener("resize", this.onResize)
    this.fill()
  },

  updated() {
    this.fill()
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize)
    clearTimeout(this.timer)
  },

  fill() {
    const items = [...this.el.children]
    const more = this.el.dataset.more === "true"
    const show = visibleCount(items.length, columnsOf(this.el), more)
    items.forEach((li, i) => li.classList.toggle("hidden", i >= show))
  },
}
