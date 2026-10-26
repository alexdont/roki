// Infinite scroll: an element at the end of a list that asks the server for more when it is about
// to come into view (`data-event`, "more" by default), as long as `data-active` is "true" — the
// server turns it off while a page is loading and when there is nothing more. After every update
// it looks again, so a short page that does not fill the screen keeps loading until it does.
export const InfiniteScroll = {
  mounted() {
    this.visible = false
    this.asked = false
    this.observer = new IntersectionObserver(
      (entries) => {
        this.visible = entries.some((e) => e.isIntersecting)
        this.check()
      },
      {rootMargin: "900px 0px"},
    )
    this.observer.observe(this.el)
  },

  updated() {
    // A new answer has come in (or not): ask again if the end is still in sight.
    this.asked = false
    this.check()
  },

  destroyed() {
    clearTimeout(this.again)
    if (this.observer) this.observer.disconnect()
  },

  check() {
    if (this.visible && !this.asked && this.el.dataset.active === "true") {
      this.asked = true
      this.pushEvent(this.el.dataset.event || "more", {})
      // A page that answers without changing this element (nothing about it says "loading") gives
      // the hook no update to look again on: look again shortly, and ask once more if the end
      // is still in sight.
      clearTimeout(this.again)
      this.again = setTimeout(() => {
        this.asked = false
        this.check()
      }, 700)
    }
  },
}
