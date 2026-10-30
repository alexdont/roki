// The trailer player on a title's page. The player (a YouTube embed: TMDB lists trailers, it does
// not host them) is made when the sheet opens and taken away when it closes, so nothing loads
// until it is asked for and a closed sheet is silent.
export const TrailerSheet = {
  mounted() {
    this.frame = () => this.el.querySelector("[data-trailer-frame]")
    this.el.addEventListener("roki:trailer-open", () => {
      const frame = this.frame()
      const key = this.el.dataset.key
      if (!frame || !key || frame.querySelector("iframe")) return
      const f = document.createElement("iframe")
      f.src = `https://www.youtube-nocookie.com/embed/${key}?autoplay=1&rel=0&modestbranding=1&playsinline=1`
      f.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen"
      f.allowFullscreen = true
      f.title = "Trailer"
      f.className = "h-full w-full border-0"
      frame.appendChild(f)
    })
    this.el.addEventListener("roki:trailer-close", () => {
      const frame = this.frame()
      if (frame) frame.textContent = ""
    })
  },
}
