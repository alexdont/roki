// The small things that make moving around the site feel smooth (styles in app.css, "Polish"):
//
//   * Pictures fade in as they arrive instead of popping in (`data-loaded` on an <img>).
//   * Sections marked `data-reveal` rise into place the first time they scroll into view
//     (`data-shown`); what is already on screen when the page opens is simply there.
//   * The header over a picture settles as the page scrolls (`--hdr`, 0 → 1 over the first
//     ~120 px), and slides away while scrolling down, back on any scroll up (`data-hdr-hidden`).
//   * Opening a poster grows its picture into the title page's artwork and opens the page out
//     from it (a view transition, run once the page is ready, the old one held still meanwhile).
//     Going back has none: the browser's own is left alone.
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
//
// Why the old page is held still by hand, and not by the transition itself: a view transition's
// update callback is meant to hold the screen while it runs, but WebKit (every browser on an
// iPhone) does not hold it through a long one. While LiveView swapped the page in, it drew every
// state the page passed through — a blank with the scroll jumped to the top, then the new page in
// full before its picture had loaded — and only then animated. So a copy of the page (`still`) is
// laid over everything at the tap and kept there while the next page loads underneath, and the
// transition runs only once that page and its picture are ready, in one synchronous step: the copy
// goes, the art is named. Nothing in between is ever drawn.

const NAME = "roki-art"
// The opening or return under way: a new one, or Back, cancels it (its copy of the page goes).
let pending = null
const cancelPending = () => { if (pending) { pending.cancel(); pending = null } }

// Waits until `found()` gives something (checked on a timer), at most `ms`; then gives it, or null.
const until = (found, ms) => new Promise((resolve) => {
  const end = Date.now() + ms
  const look = () => {
    const x = found()
    if (x || Date.now() > end) resolve(x || null)
    else setTimeout(look, 30)
  }
  look()
})

// An element of the live page — never of the copy held over it.
const live = (sel) => document.querySelector(`[data-phx-main] ${sel}`)

const named = (el) => { if (el) el.style.viewTransitionName = NAME }
const unname = () => { for (const el of document.querySelectorAll(`[style*="${NAME}"]`)) el.style.viewTransitionName = "" }

// What lies over the art on the title page — its shading, the words and buttons — moves into the
// transition with it, each under a name of its own, so it is drawn above the growing picture (the
// art would otherwise cover it all the way and only drop behind it at the end, in one jump).
// The names follow document order, which is the order they are drawn in.
const nameOver = (hero) => {
  if (!hero) return
  hero.querySelectorAll(":scope > [data-hero-fade], :scope > [data-hero-content]")
    .forEach((el, i) => { el.style.viewTransitionName = `${NAME}-over-${i}` })
}

// A copy of the page as it is on screen, over everything (`data-still`, app.css), for the eye to
// rest on while the next page loads underneath. The page's own elements copied, not a picture of
// them: the transition can then find the poster (or the art) in it. Only what is on the screen is
// copied in full — what lies off it is kept as an empty box of its size, so the page keeps its
// length and its scroll without its thousands of elements (a page is a few thousand; copying it
// whole took a third of a second). Stripped of everything that made it a LiveView, so nothing in it
// is a view, a hook, bound or sticky; drawings are copied over, since they do not come with their
// canvases. `els` are elements of the page whose copies are wanted back (`twins`, same order).
function still(...els) {
  const box = document.createElement("div")
  box.setAttribute("data-still", "")
  box.setAttribute("aria-hidden", "true")
  const bg = [document.body, root].map((el) => getComputedStyle(el).backgroundColor)
    .find((c) => c && c !== "transparent" && c !== "rgba(0, 0, 0, 0)")
  if (bg) box.style.background = bg
  const twins = new Map(els.map((el) => [el, null]))
  const scrolled = []
  const seen = (r) => r.bottom >= -1 && r.top <= innerHeight + 1 && r.right >= -1 && r.left <= innerWidth + 1
  const boxLike = (el) => {
    const d = document.createElement("div")
    d.className = el.className
    if (el.getAttribute("style")) d.setAttribute("style", el.getAttribute("style"))
    return d
  }
  const drawn = (img) => {
    const c = document.createElement("canvas")
    for (const a of ["class", "style", "width", "height"]) if (img.hasAttribute(a)) c.setAttribute(a, img.getAttribute(a))
    // Its own size, as the picture's, so `object-fit` lays it out the same; large ones cut down.
    const k = Math.min(1, 1600 / Math.max(img.naturalWidth, img.naturalHeight))
    c.width = Math.round(img.naturalWidth * k)
    c.height = Math.round(img.naturalHeight * k)
    try { c.getContext("2d").drawImage(img, 0, 0, c.width, c.height) } catch (_) { /* blank, then */ }
    return c
  }
  const strip = (el) => {
    for (const a of [...el.attributes]) if (a.name.startsWith("phx-") || a.name.startsWith("data-phx-")) el.removeAttribute(a.name)
  }
  const copy = (el) => {
    const r = el.getBoundingClientRect()
    // A frame or a player copied would load (and play) again: a box of its size in its place.
    const boxed = /^(IFRAME|VIDEO|AUDIO|OBJECT|EMBED)$/.test(el.tagName)
    // A picture copied as an <img> is fetched and decoded again — Safari shows it blank meanwhile
    // (a frame of dark cards): its pixels are drawn into a canvas instead, at once.
    const c = boxed ? boxLike(el) : el.tagName === "IMG" && seen(r) && el.complete && el.naturalWidth ? drawn(el) : el.cloneNode(false)
    strip(c)
    if (twins.has(el)) twins.set(el, c)
    if (boxed || !seen(r)) {
      // Its box only (`box-sizing: border-box` everywhere, so its outer size).
      if (r.height) c.style.height = `${r.height}px`
      c.style.overflow = "hidden"
      return c
    }
    if (el.tagName === "CANVAS") { try { c.getContext("2d").drawImage(el, 0, 0) } catch (_) { /* a blank one, then */ } }
    // As it is on the screen this instant: a poster lifted by the hover a tap brings, a picture
    // zoomed — the copy is not hovered, and would settle them back (the poster seen to move a
    // little at the tap).
    const cs = getComputedStyle(el)
    for (const prop of ["transform", "translate", "scale", "rotate"]) {
      if (cs[prop] && cs[prop] !== "none") c.style[prop] = cs[prop]
    }
    // A row scrolled sideways (a list scrolled down): a copy starts at its beginning, so where it
    // is is kept to set once the copy is in place.
    if (el.scrollLeft || el.scrollTop) scrolled.push([c, el.scrollLeft, el.scrollTop])
    for (const n of el.childNodes) {
      if (n.nodeType === 3) c.appendChild(n.cloneNode())
      else if (n.nodeType === 1 && n.tagName !== "SCRIPT") c.appendChild(copy(n))
    }
    return c
  }
  for (const child of document.body.children) {
    if (child.tagName === "SCRIPT" || child.hasAttribute("data-still")) continue
    const c = copy(child)
    c.removeAttribute("id")
    box.appendChild(c)
  }
  document.body.appendChild(box)
  // Scrolled as the page is: sticky things sit where they sat.
  box.scrollTop = scrollY
  box.scrollLeft = scrollX
  for (const [c, left, top] of scrolled) { c.scrollLeft = left; c.scrollTop = top }
  return {twins: els.map((el) => twins.get(el)), remove: () => box.remove()}
}

// The page's art, there in full before the transition takes its picture of the new page: a
// picture still on its way (or still fading in, as pictures do here) would be caught as an empty
// box and pop in a moment later. Waits for it to be decoded, at most `ms`, and shows it at once,
// without its own fade.
const ready = async (img, ms) => {
  if (!img) return
  img.style.transition = "none"
  if (!(img.complete && img.naturalWidth)) {
    await Promise.race([img.decode().catch(() => {}), new Promise((r) => setTimeout(r, ms))])
  }
  img.dataset.loaded = ""
  setTimeout(() => { img.style.transition = "" }, 1500)
}

// The poster's place on the screen, as a clip-path inset from each edge.
const insetOf = (el) => {
  const r = el.getBoundingClientRect()
  const px = (n) => `${Math.max(0, Math.round(n))}px`
  return `inset(${px(r.top)} ${px(innerWidth - r.right)} ${px(innerHeight - r.bottom)} ${px(r.left)} round 12px)`
}
const FULL = "inset(0px 0px 0px 0px round 0px)"
const EASE = "cubic-bezier(0.3, 0.75, 0.2, 1)"

// The page seen through a frame that opens out of the poster (or closes into it), at the art's
// pace. Run from script on the transition's own pseudo-element — keyframes with variables in them
// are not read the same by every browser, and one that did not would show the whole page at once.
const reveal_ = (pseudo, from, to, ms) =>
  root.animate({clipPath: [from, to]}, {duration: ms, easing: EASE, fill: "both", pseudoElement: pseudo})

// `data-vt` says which way the transition runs, for app.css (it holds the pages still and leaves
// the frame to the script above). Set only once it is sure to run, cleared when it ends.
const setDir = (dir) => { if (dir) root.dataset.vt = dir; else delete root.dataset.vt }

// Runs `update` (synchronous: the pages are ready) in a view transition and `animate` once its
// layers are there; `update` giving nothing means there is nothing to animate, and the change is
// simply made.
function run(update, animate) {
  let plan = null
  const vt = document.startViewTransition(() => {
    plan = update()
    // Before the browser lays out its pictures of the pages, so the CSS for this way applies from
    // the very first frame. The frame's start is there too (`--vt-from`), for that first frame.
    if (plan) { setDir(plan.dir); root.style.setProperty("--vt-from", plan.from || FULL) }
  })
  let anim = null
  vt.updateCallbackDone.then(() => { if (!plan) vt.skipTransition() }, () => {})
  vt.ready.then(() => { if (plan) anim = animate(plan) }, () => {})
  // The frame's animation is cancelled with its transition: one kept (it holds its last state) would
  // take hold of the same pseudo-element in the next transition, clipping a page that should show.
  vt.finished.catch(() => {}).finally(() => { if (anim) anim.cancel(); unname(); setDir(null) })
}

function transitions() {
  if (!document.startViewTransition) return
  // A poster opening its title page: the picture grows into the page's art, and the page itself
  // opens out from where the poster was, through a frame that grows with it.
  document.addEventListener("click", (e) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || reduced()) return
    const a = e.target.closest && e.target.closest("a[href^='/title/']")
    if (!a || !a.hasAttribute("data-phx-link")) return
    // The picture that travels: the card's wide one when its card is open (what is seen; the
    // poster is behind it), else the poster.
    const open = a.closest("[data-card][data-open]")
    const img = (open && open.querySelector("[data-card-img][data-loaded]")) || a.querySelector("img") || a.closest("[data-card], li")?.querySelector("img")
    if (!img || !img.hasAttribute("data-loaded")) return
    const path = new URL(a.href).pathname
    const from = insetOf(img)
    cancelPending()
    unname()
    const held = still(img)
    const [poster] = held.twins
    let stop = false
    pending = {cancel: () => { stop = true; held.remove() }}
    ;(async () => {
      // The title page itself, not a moment of the old one. A navigation slower than this goes
      // ahead without the animation.
      const art = await until(() => !stop && location.pathname === path && live("[data-hero] > img"), 2500)
      if (stop) return
      if (!art || !poster) { held.remove(); pending = null; return }
      await ready(art, 900)
      if (stop) return
      // The title page starts at its top; LiveView's own scroll there may still be a frame away.
      if (scrollY) scrollTo(0, 0)
      named(poster)
      pending = null
      run(() => {
        held.remove()
        // The page's first patch can have put a new top section in since (the same picture, from
        // the cache): the art that is there now is the one that moves, shown at once.
        const now = live("[data-hero] > img") || art
        if (now !== art) { now.style.transition = "none"; now.dataset.loaded = "" }
        named(now)
        nameOver(now.closest("[data-hero]"))
        return {dir: "open", from}
      }, (plan) => reveal_("::view-transition-new(root)", plan.from, FULL, 500))
    })()
  }, true)
  // Going back is left to the browser: its own swipe or button already animates it, and waiting for
  // the page to come back so as to animate it a second time made it slow. Only an opening still
  // under way is let go of, so its held copy of the page does not stay over the page going back to.
  addEventListener("popstate", () => { cancelPending() }, true)
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
