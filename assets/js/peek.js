// The hover card on a poster: what the title is — year, length, rating, genres, a few lines of
// the story — plus where you are in it. Only the facts the page already has are drawn at
// once; the rest comes from `/peek/:type/:id` the first time you rest the pointer on a poster
// (the server remembers it, and so does this page). Mouse only: a touch screen has no hover.
const DELAY_MS = 350
const cache = new Map()
let card = null
let timer = null
let current = null
let hideTimer = null
let currentInfo
let currentState = null

// relatedTarget is null or not even a node (leaving the window): not inside anything.
const within = (node, other) => !!node && other instanceof Node && node.contains(other)

const csrf = () => document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""

function ensureCard() {
  if (card) return card
  card = document.createElement("div")
  card.className = "peek-card"
  card.setAttribute("role", "tooltip")
  document.body.appendChild(card)
  return card
}

// "Released 3 Mar 2026 (233 days ago)" — a show says "First aired".
export function released(iso, key = "") {
  const [y, m, d] = iso.split("-").map(Number)
  if (!y || !m || !d) return ""
  const date = new Date(y, m - 1, d)
  const now = new Date()
  const days = Math.round((new Date(now.getFullYear(), now.getMonth(), now.getDate()) - date) / 86400000)
  const when = date.toLocaleDateString("en-GB", {day: "numeric", month: "short", year: "numeric"})
  const ago = days <= 0 ? "today" : days === 1 ? "yesterday" : `${days.toLocaleString("en-GB")} days ago`
  return `${key.startsWith("tv/") ? "First aired" : "Released"} ${when} (${ago})`
}

function line(cls, text) {
  const el = document.createElement("div")
  el.className = cls
  el.textContent = text
  return el
}

function render(el, info) {
  const c = ensureCard()
  c.textContent = ""

  c.appendChild(line("peek-title", info?.title || el.dataset.peekTitle || ""))

  const facts = info
    ? [info.year, info.minutes && `${info.minutes} min`, info.seasons && `${info.seasons} season${info.seasons > 1 ? "s" : ""}`, info.vote > 0 && `★ ${info.vote.toFixed(1)}`].filter(Boolean)
    : []
  if (facts.length) c.appendChild(line("peek-facts", facts.join(" · ")))

  if (info?.genres?.length) {
    const row = document.createElement("div")
    row.className = "peek-genres"
    for (const g of info.genres) row.appendChild(line("peek-chip", g))
    c.appendChild(row)
  }

  if (info?.overview) c.appendChild(line("peek-overview", info.overview))
  else if (info === undefined) c.appendChild(line("peek-muted", "…"))

  if (el.dataset.peekProgress) c.appendChild(line("peek-progress", el.dataset.peekProgress))
  if (el.dataset.peekResume) c.appendChild(line("peek-progress", el.dataset.peekResume))
  // Not out yet (red, from the page) or out already (grey, when the lookup arrives).
  if (el.dataset.peekDue) c.appendChild(line("peek-due", el.dataset.peekDue))
  else if (info?.date) c.appendChild(line("peek-released", released(info.date, el.dataset.peek)))

  const actions = actionRow(el)
  if (actions) c.appendChild(actions)

  place(el)
}

// Save for later / mark watched, straight from the card. Shown once the server has said where the
// title stands for this account (nothing for a guest or an account without a shelf).
function actionRow(el) {
  if (!currentState) return null
  const row = document.createElement("div")
  row.className = "peek-actions"
  const series = el.dataset.peek.startsWith("tv/")
  // The same icons and colours as the buttons on the title page; the words are the tooltip.
  const buttons = [
    ["saved", currentState.saved, "bookmark", "Saved for later (click to remove)", "Save for later"],
    [
      "watched",
      currentState.watched,
      "eye",
      series ? "Completed (click to mark as not watched)" : "Watched (click to mark as not watched)",
      series ? "Mark as completed" : "Mark as watched",
    ],
  ]
  for (const [what, on, icon, onLabel, offLabel] of buttons) {
    const b = document.createElement("button")
    b.type = "button"
    b.className = "peek-btn"
    b.dataset.on = String(on)
    b.dataset.what = what
    b.title = on ? onLabel : offLabel
    b.setAttribute("aria-label", b.title)
    const ico = document.createElement("span")
    ico.className = `peek-ico ${on ? `hero-${icon}-solid` : `hero-${icon}`}`
    b.appendChild(ico)
    row.appendChild(b)
  }
  return row
}

async function act(el, what, button) {
  button.disabled = true
  button.textContent = "…"
  try {
    const res = await fetch(`/library/${el.dataset.peek}/${what}`, {
      method: "POST",
      credentials: "same-origin",
      headers: {"x-csrf-token": csrf(), accept: "application/json"},
    })
    if (res.ok) currentState = await res.json()
  } catch (_e) {
    // leave the state as it was
  }
  // On a list that is only saved titles, taking one off the card takes its tile off the page too.
  if (what === "saved" && currentState && !currentState.saved) {
    const unsave = el.closest("li")?.querySelector('button[phx-click="unsave"]')
    if (unsave) {
      hide()
      unsave.click()
      return
    }
  }
  if (currentState) {
    // The poster greys out like any watched title, without waiting for the page to refresh.
    el.closest("a")?.classList.toggle("opacity-50", currentState.watched)
    el.querySelector("img")?.classList.toggle("grayscale", currentState.watched)
  }
  if (current === el) render(el, currentInfo)
}

async function loadState(key) {
  try {
    const res = await fetch(`/library/${key}`, {credentials: "same-origin", cache: "no-store"})
    return res.ok ? await res.json() : null
  } catch (_e) {
    return null
  }
}

// Beside the poster, on whichever side has room, kept inside the window.
function place(el) {
  const c = ensureCard()
  const r = el.getBoundingClientRect()
  const w = c.offsetWidth
  const h = c.offsetHeight
  const gap = 10
  let left = r.right + gap
  if (left + w > window.innerWidth - 8) left = Math.max(8, r.left - gap - w)
  let top = r.top
  top = Math.min(top, window.innerHeight - h - 8)
  c.style.left = `${left}px`
  c.style.top = `${Math.max(8, top)}px`
  c.dataset.show = "true"
}

async function load(key) {
  if (cache.has(key)) return cache.get(key)
  try {
    const res = await fetch(`/peek/${key}?v=2`, {credentials: "same-origin"})
    const info = res.ok ? await res.json() : null
    cache.set(key, info)
    return info
  } catch {
    return null
  }
}

function hide() {
  clearTimeout(timer)
  clearTimeout(hideTimer)
  current = null
  currentState = null
  if (card) card.dataset.show = "false"
}

// Leaving the poster hides the card a moment later, so the pointer can cross to the card (it has
// buttons) without it vanishing; coming onto the poster or the card cancels it.
function hideSoon() {
  clearTimeout(hideTimer)
  hideTimer = setTimeout(hide, 220)
}

export function setupPeek() {
  if (!window.matchMedia("(hover: hover)").matches) return

  document.addEventListener("mouseover", (e) => {
    const el = e.target.closest?.("[data-peek-title]")
    // The home page's rows open a card of their own (shelf_row.js).
    // …and so do the grids' (grid_cards.js): a poster inside either has no card of this kind.
    if (el?.closest("[data-card-row], [data-card]")) return
    if (el && el === current) clearTimeout(hideTimer)
    if (!el || el === current || within(el, e.relatedTarget)) return
    hide()
    current = el
    timer = setTimeout(async () => {
      const key = el.dataset.peek
      currentInfo = cache.has(key) ? cache.get(key) : undefined
      render(el, currentInfo)
      const [info, state] = await Promise.all([load(key), loadState(key)])
      if (current !== el) return
      currentInfo = info
      currentState = state
      render(el, info)
    }, DELAY_MS)
  })

  document.addEventListener("mouseout", (e) => {
    const el = e.target.closest?.("[data-peek-title]")
    if (el && el === current && !within(el, e.relatedTarget) && !within(card, e.relatedTarget)) hideSoon()
  })

  // The card itself: stays while the pointer is on it, goes shortly after it leaves, and its
  // buttons act on the title it describes.
  ensureCard()

  // A right click or a context menu can swallow the "mouseout", leaving the card up for good: so
  // the pointer is watched too, and a card it is not on (poster or card) goes after a moment.
  let pointerOn = false
  let awaySince = 0
  document.addEventListener("mousemove", (e) => {
    pointerOn = !!(e.target.closest && e.target.closest("[data-peek-title], .peek-card"))
  }, {passive: true})
  const away = () => { pointerOn = false }
  document.addEventListener("contextmenu", away)
  document.documentElement.addEventListener("mouseleave", away)
  window.addEventListener("blur", away)
  setInterval(() => {
    if (!current || pointerOn) { awaySince = 0; return }
    awaySince = awaySince || Date.now()
    if (Date.now() - awaySince >= 1500) { awaySince = 0; hide() }
  }, 300)

  card.addEventListener("mouseenter", () => clearTimeout(hideTimer))
  card.addEventListener("mouseleave", (e) => {
    if (!current || !within(current, e.relatedTarget)) hideSoon()
  })
  card.addEventListener("click", (e) => {
    const button = e.target.closest?.("button[data-what]")
    if (button && current && !button.disabled) act(current, button.dataset.what, button)
  })

  const inCard = (e) => within(card, e.target)
  for (const ev of ["scroll", "wheel", "click", "phx:page-loading-start"]) {
    window.addEventListener(ev, (e) => { if (!inCard(e)) hide() }, {passive: true, capture: true})
  }
}
