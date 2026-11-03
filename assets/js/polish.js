// The small things that make moving around the site feel smooth (styles in app.css, "Polish"):
//
//   * Pictures fade in as they arrive instead of popping in (`data-loaded` on an <img>).
//   * Sections marked `data-reveal` rise into place the first time they scroll into view
//     (`data-shown`); what is already on screen when the page opens is simply there.
//   * The header over a picture settles as the page scrolls (`--hdr`, 0 → 1 over the first
//     ~120 px), and slides away while scrolling down, back on any scroll up (`data-hdr-hidden`).
//   * Opening a poster grows its picture into the title page's artwork (a view transition), and
//     going back shrinks it into its poster again.
//
// LiveView's patches keep only the attributes the server sends, so `keep` (LiveSocket's
// `dom.onBeforeElUpdated`) carries `data-loaded` and `data-shown` over: nothing fades twice.

const root = document.documentElement
const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches

// ── pictures ───────────────────────────────────────────────────────────

const loaded = (img) => { if (img.tagName === "IMG") img.dataset.loaded = "" }

export function keep(from, to) {
  if (from.tagName === "IMG" && from.hasAttribute("data-loaded") && from.getAttribute("src") === to.getAttribute("src")) {
    to.setAttribute("data-loaded", "")
  }
  if (from.hasAttribute && from.hasAttribute("data-shown")) {
    to.setAttribute("data-shown", "")
    if (from.hasAttribute("data-instant")) to.setAttribute("data-instant", "")
  }
}

function pictures() {
  // What has arrived already shows at once; the fading is only for what arrives after.
  for (const img of document.images) if (img.complete) loaded(img)
  document.addEventListener("load", (e) => loaded(e.target), true)
  document.addEventListener("error", (e) => loaded(e.target), true)
  // A picture put on the page already loaded (from the cache, in a patch) fires no load event.
  new MutationObserver((list) => {
    for (const m of list) for (const n of m.addedNodes) {
      if (n.nodeType !== 1) continue
      if (n.tagName === "IMG" && n.complete && n.naturalWidth) loaded(n)
      else if (n.querySelectorAll) for (const img of n.querySelectorAll("img")) if (img.complete && img.naturalWidth) loaded(img)
    }
  }).observe(document.body, {childList: true, subtree: true})
  root.classList.add("img-fade")
}

// ── sections rising into place ─────────────────────────────────────────

let revealer = null
function reveal() {
  if (reduced() || !("IntersectionObserver" in window)) {
    for (const el of document.querySelectorAll("[data-reveal]")) el.dataset.shown = ""
    return
  }
  revealer = revealer || new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.dataset.shown = ""; revealer.unobserve(e.target) }
  }, {rootMargin: "0px 0px -8% 0px"})
  for (const el of document.querySelectorAll("[data-reveal]:not([data-shown])")) {
    // On screen already when found: there, not animated in.
    const r = el.getBoundingClientRect()
    if (r.top < innerHeight && r.bottom > 0) { el.dataset.shown = ""; el.dataset.instant = ""; continue }
    revealer.observe(el)
  }
}

// ── the header ─────────────────────────────────────────────────────────

function header() {
  let last = scrollY, frame = null
  const update = () => {
    frame = null
    const y = Math.max(0, scrollY)
    root.style.setProperty("--hdr", Math.min(1, y / 120).toFixed(3))
    root.toggleAttribute("data-scrolled", y > 60)
    // Away while going down a good way into the page; back on the first move up. Never while
    // something in it is open or has the focus.
    const head = document.querySelector(".site-header")
    const busy = head && (head.matches(":focus-within") || head.querySelector("[open], .dropdown:focus-within, #search-pop:not(.hidden)"))
    if (y < 300 || y < last - 4 || busy) root.removeAttribute("data-hdr-hidden")
    else if (y > last + 4) root.setAttribute("data-hdr-hidden", "")
    if (Math.abs(y - last) > 4) last = y
  }
  addEventListener("scroll", () => { frame = frame || requestAnimationFrame(update) }, {passive: true})
  addEventListener("phx:page-loading-stop", () => { last = scrollY; root.removeAttribute("data-hdr-hidden"); update() })
  update()
}

// ── a poster growing into its page ─────────────────────────────────────

const NAME = "roki-art"
let lastKey = null

// The page that opens is done when LiveView says so, or after a short while at the most: a view
// transition holds the screen still while it waits.
const pageDone = (ms) => new Promise((resolve) => {
  const t = setTimeout(resolve, ms)
  // Not a frame later: the browser draws no frames while a transition holds the screen.
  addEventListener("phx:page-loading-stop", () => { clearTimeout(t); setTimeout(resolve, 0) }, {once: true})
})

const named = (el) => { if (el) el.style.viewTransitionName = NAME }
const unname = () => { for (const el of document.querySelectorAll(`[style*="${NAME}"]`)) el.style.viewTransitionName = "" }

function transitions() {
  if (!document.startViewTransition) return
  // A poster opening its title page.
  document.addEventListener("click", (e) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || reduced()) return
    const a = e.target.closest && e.target.closest("a[href^='/title/']")
    if (!a || !a.hasAttribute("data-phx-link")) return
    const img = a.querySelector("img") || a.closest("[data-card], li")?.querySelector("img")
    if (!img || !img.hasAttribute("data-loaded")) return
    unname()
    named(img)
    lastKey = new URL(a.href).pathname
    const vt = document.startViewTransition(async () => {
      await pageDone(700)
      unname()
      named(document.querySelector("[data-hero] > img"))
    })
    vt.finished.catch(() => {}).finally(unname)
    vt.ready.catch(() => {})
  }, true)
  // Back from a title page to where it was opened: the artwork shrinks into its poster again.
  addEventListener("popstate", () => {
    if (reduced() || !lastKey || !location.pathname.match(/^\/(home|movies|shows|anime|search|mood|lists)/)) return
    const art = document.querySelector("[data-hero] > img")
    if (!art) return
    const key = lastKey
    unname()
    named(art)
    const vt = document.startViewTransition(async () => {
      await pageDone(700)
      unname()
      const link = document.querySelector(`a[href="${key}"] img, a[href^="${key}?"] img`)
      if (link && link.getBoundingClientRect().bottom > 0 && link.getBoundingClientRect().top < innerHeight) named(link)
    })
    vt.finished.catch(() => {}).finally(unname)
    vt.ready.catch(() => {})
  }, true)
}

export function polish() {
  pictures()
  header()
  transitions()
  reveal()
  addEventListener("phx:page-loading-stop", () => requestAnimationFrame(reveal))
  // Sections that come in later with a patch (the Lists row, the activity) are found too.
  new MutationObserver(() => { if (document.querySelector("[data-reveal]:not([data-shown])")) reveal() })
    .observe(document.body, {childList: true, subtree: true})
}
