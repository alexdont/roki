// The title page's colours on the whole document (Roki.Palette): the page's wrapper carries them
// for the first paint; this copies them to <html> so the floating header, the page behind the
// sections and the sheets match, and takes them off again when the page is left.
const VARS = ["--th", "--tc", "--ah", "--ac"]

export const TitleTint = {
  mounted() { this.apply() },
  updated() { this.apply() },
  destroyed() { clear() },
  apply() {
    const root = document.documentElement
    for (const v of VARS) root.style.setProperty(v, this.el.style.getPropertyValue(v))
    root.setAttribute("data-tint", "on")
  },
}

function clear() {
  const root = document.documentElement
  for (const v of VARS) root.style.removeProperty(v)
  root.removeAttribute("data-tint")
}
