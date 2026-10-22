// The hover card on a poster: what the title is — year, length, rating, genres, a few lines of
// the story — plus where you are in it. Only the facts the page already has are drawn at
// once; the rest comes from `/peek/:type/:id` the first time you rest the pointer on a poster
// (the server remembers it, and so does this page). Mouse only: a touch screen has no hover.
const DELAY_MS = 350
const cache = new Map()
let card = null
let timer = null
let current = null

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
  if (el.dataset.peekCached) c.appendChild(line("peek-cached", "⚡ sources cached — plays right away"))

  place(el)
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
  current = null
  if (card) card.dataset.show = "false"
}

export function setupPeek() {
  if (!window.matchMedia("(hover: hover)").matches) return

  document.addEventListener("mouseover", (e) => {
    const el = e.target.closest?.("[data-peek]")
    if (!el || el === current || el.contains(e.relatedTarget)) return
    hide()
    current = el
    timer = setTimeout(async () => {
      const key = el.dataset.peek
      render(el, cache.has(key) ? cache.get(key) : undefined)
      const info = await load(key)
      if (current === el) render(el, info)
    }, DELAY_MS)
  })

  document.addEventListener("mouseout", (e) => {
    const el = e.target.closest?.("[data-peek]")
    if (el && el === current && !el.contains(e.relatedTarget)) hide()
  })

  for (const ev of ["scroll", "wheel", "click", "phx:page-loading-start"]) {
    window.addEventListener(ev, hide, {passive: true, capture: true})
  }
}
