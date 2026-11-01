// The bookmark on a poster that is on your saved list (`posters.ex` draws it with the page): saving
// or un-saving from the card that opens over a poster draws or takes away the same mark at once,
// not at the next visit. The classes are the ones `posters.ex` uses, which is where the stylesheet
// finds them.
const CLASSES =
  "absolute right-2.5 top-0 z-10 block h-5 w-3 bg-primary/70 saturate-[0.7] drop-shadow-[0_1px_1px_rgb(0_0_0/0.3)] [clip-path:polygon(0_0,100%_0,100%_100%,50%_72%,0_100%)]"

// `box` is the poster's own box (the element with `data-peek`).
export function setSavedMark(box, saved) {
  if (!box) return
  const mark = box.querySelector("[data-saved-mark]")

  if (saved && !mark) {
    const el = document.createElement("span")
    el.dataset.savedMark = ""
    el.title = "Saved for later"
    el.className = CLASSES
    el.innerHTML = '<span class="sr-only">Saved for later</span>'
    box.appendChild(el)
  } else if (!saved && mark) {
    mark.remove()
  }
}
