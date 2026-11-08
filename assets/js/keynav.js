// Browsing with the keyboard, like a TV app: the arrow keys move from one poster, tab or button to
// the nearest one in that direction, Enter opens it and Space plays a title. Plain focus does the
// work — posters, tabs, chips and the header are already links and buttons — so the rings are the
// ones the site already draws for a focused poster (app.css), and a screen reader hears the same.
//
// It stays out of the way: the first arrow press wakes it (and focuses the first thing on the
// screen), a mouse movement or a click puts it to sleep again, a text field and the rating slider
// keep their own arrows, the player (`#study`) and the readers have their own keys, and a device
// can switch it off for good (`localStorage["roki:keynav"] = "off"`, Settings → Keyboard browsing).

const KEY = "roki:keynav"
const HINT = "roki:keynav:hint"
const DIRS = {ArrowLeft: "left", ArrowRight: "right", ArrowUp: "up", ArrowDown: "down"}

const CANDIDATES = [
  "a[href]", "button", "summary", "[role=tab]", "[role=button]", "[role=menuitem]",
  "input:not([type=hidden]):not([type=range])", "select", "[tabindex]",
].join(",")

// Where an open sheet or dialog traps the arrows: only what is inside it can be reached.
const TRAPS = "dialog[open], [role=dialog], #rate-sheet:not(.hidden), #link-sheet:not(.hidden), .modal-open, .modal[open]"

export const keynav = {
  enabled() { try { return localStorage.getItem(KEY) !== "off" } catch { return true } },
  set(on) {
    try { on ? localStorage.removeItem(KEY) : localStorage.setItem(KEY, "off") } catch {}
    if (!on) sleep()
    toggles.forEach(reflect)
  },
}

let awake = false
const toggles = new Set()

function wake() {
  if (awake) return
  awake = true
  document.documentElement.dataset.keynav = "on"
  hint()
}

function sleep() {
  awake = false
  delete document.documentElement.dataset.keynav
}

// Where the keys do nothing: another part of the site owns them.
function elsewhere() {
  return !document.querySelector("[data-phx-main]") || document.querySelector("#study, .fresco, [data-no-keynav]")
}

function typing(el) {
  if (!el || el === document.body) return false
  if (el.isContentEditable) return true
  const tag = el.tagName
  if (tag === "TEXTAREA" || tag === "SELECT") return true
  if (tag === "INPUT") return true
  return false
}

function visible(el) {
  if (el.closest("template, [hidden], [inert], .sr-only")) return false
  if (el.disabled || el.getAttribute("tabindex") === "-1" && !el.matches("a[href], button")) return false
  const r = el.getBoundingClientRect()
  if (r.width < 8 || r.height < 8) return false
  const cs = getComputedStyle(el)
  return cs.visibility !== "hidden" && cs.display !== "none" && cs.pointerEvents !== "none"
}

// One stop per poster (its link), not the buttons of a card that has opened over it.
function stop(el) {
  const li = el.closest("[data-card]")
  if (!li) return true
  return el === li.querySelector("a[href]")
}

function candidates() {
  const trap = Array.from(document.querySelectorAll(TRAPS)).find((t) => t.getClientRects().length)
  const root = trap || document
  return Array.from(root.querySelectorAll(CANDIDATES)).filter((el) => {
    if (el.getAttribute("tabindex") === "-1") return false
    // (The fanned posters in the mood banner are decoration for "Show me all".)
    if (el.closest(".study-immersive, .study-ui, .mood-fan")) return false
    return stop(el) && visible(el)
  })
}

// The nearest in the direction: along it the gap between the two edges, across it the distance
// between the centres, counted double so that "down" prefers the one underneath to the one that is
// merely lower.
function pick(cur, list, dir) {
  const c = cur.getBoundingClientRect()
  const cx = c.left + c.width / 2, cy = c.top + c.height / 2
  let best = null, bestCost = Infinity
  for (const el of list) {
    if (el === cur) continue
    const r = el.getBoundingClientRect()
    const px = r.left + r.width / 2, py = r.top + r.height / 2
    let along, across
    if (dir === "right") { if (!(r.left > c.left + c.width * 0.5)) continue; along = Math.max(0, r.left - c.right); across = Math.abs(py - cy) }
    else if (dir === "left") { if (!(r.right < c.right - c.width * 0.5)) continue; along = Math.max(0, c.left - r.right); across = Math.abs(py - cy) }
    else if (dir === "down") { if (!(r.top > c.top + c.height * 0.5)) continue; along = Math.max(0, r.top - c.bottom); across = Math.abs(px - cx) }
    else { if (!(r.bottom < c.bottom - c.height * 0.5)) continue; along = Math.max(0, c.top - r.bottom); across = Math.abs(px - cx) }
    const cost = along + across * 2
    if (cost < bestCost) { best = el; bestCost = cost }
  }
  return best
}

// The first thing to land on: the first poster or button in the page below the header, else the
// first at all.
function first(list) {
  const header = document.querySelector(".site-header")
  const top = header ? header.getBoundingClientRect().bottom : 0
  const inView = list.filter((el) => {
    const r = el.getBoundingClientRect()
    return r.bottom > top + 8 && r.top < innerHeight && r.right > 0 && r.left < innerWidth && !(header && header.contains(el))
  })
  const pool = inView.length ? inView : list
  return pool.sort((a, b) => {
    const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect()
    return Math.round(ra.top / 40) - Math.round(rb.top / 40) || ra.left - rb.left
  })[0]
}

function land(el) {
  el.focus({preventScroll: true})
  const r = el.getBoundingClientRect()
  const header = document.querySelector(".site-header")
  const top = header && !document.documentElement.hasAttribute("data-hdr-hidden") ? header.getBoundingClientRect().bottom : 0
  const fits = r.top >= top + 8 && r.bottom <= innerHeight - 8
  el.scrollIntoView({block: fits ? "nearest" : "center", inline: "nearest"})
}

function isPoster(el) {
  return el && el.matches && el.matches("a[href]") && el.closest("[data-card]")
}

// Space on a poster plays it (the card's Play: a film goes to its sources, a show to its page).
function play(el) {
  const li = el.closest("[data-card]")
  const to = li && li.dataset.playHref
  if (!to) { el.click(); return }
  const a = document.createElement("a")
  a.href = to
  a.setAttribute("data-phx-link", "redirect")
  a.setAttribute("data-phx-link-state", "push")
  a.hidden = true
  document.body.appendChild(a)
  a.click()
  a.remove()
}

function onKey(e) {
  if (!keynav.enabled() || e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey || elsewhere()) return
  const active = document.activeElement
  const dir = DIRS[e.key]

  if (e.key === "Escape") { if (awake && active && active !== document.body && !typing(active)) { active.blur(); sleep() } return }

  if (e.key === " " || e.code === "Space") {
    if (!awake || typing(active) || !active || active === document.body) return
    if (isPoster(active)) { e.preventDefault(); play(active) }
    else if (active.matches("a[href], [role=tab], [role=button]")) { e.preventDefault(); active.click() }
    return
  }

  if (!dir) return

  // A text box keeps Left and Right; Up and Down leave it. The slider, selects and anything else
  // that uses the arrows itself are left alone.
  if (active && (active.matches("input[type=range], select, textarea, [contenteditable]") || (active.tagName === "INPUT" && (dir === "left" || dir === "right")))) return
  if (active && active.closest("[role=listbox], [role=menu], .study-pop")) return

  const list = candidates()
  if (!list.length) return
  wake()

  const here = active && active !== document.body && list.includes(active) ? active : null
  const next = here ? pick(here, list, dir) : first(list)
  if (!next) return  // nothing further that way: the page scrolls as it always did
  e.preventDefault()
  land(next)
}

function hint() {
  let seen = false
  try { seen = localStorage.getItem(HINT) === "1"; localStorage.setItem(HINT, "1") } catch {}
  if (seen) return
  const el = document.createElement("div")
  el.className = "keynav-hint"
  el.setAttribute("role", "status")
  el.innerHTML = "<kbd>←</kbd><kbd>↑</kbd><kbd>↓</kbd><kbd>→</kbd> move <span>·</span> <kbd>Enter</kbd> open <span>·</span> <kbd>Space</kbd> play <span>·</span> <kbd>Esc</kbd> stop"
  document.body.appendChild(el)
  setTimeout(() => el.classList.add("keynav-hint-out"), 5000)
  setTimeout(() => el.remove(), 5600)
}

function reflect(btn) {
  const on = keynav.enabled()
  btn.setAttribute("aria-pressed", String(on))
  btn.textContent = on ? "On" : "Off"
  btn.classList.toggle("btn-primary", on)
}

// The Settings switch: a LiveView hook, so a patch keeps its look.
export const KeynavToggle = {
  mounted() {
    toggles.add(this.el)
    this.el.addEventListener("click", () => keynav.set(!keynav.enabled()))
    reflect(this.el)
  },
  updated() { reflect(this.el) },
  destroyed() { toggles.delete(this.el) },
}

export function setupKeynav() {
  window.addEventListener("keydown", onKey)
  // Real movement of the mouse, or a click, hands the screen back to the pointer.
  let lx = null, ly = null
  window.addEventListener("mousemove", (e) => {
    if (lx !== null && (Math.abs(e.clientX - lx) > 3 || Math.abs(e.clientY - ly) > 3)) sleep()
    lx = e.clientX; ly = e.clientY
  }, {passive: true})
  window.addEventListener("pointerdown", sleep, {passive: true})
}
