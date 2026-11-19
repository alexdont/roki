// The profile's world map (ALEX-157): the outlines are a static SVG (`data-src`, Natural Earth,
// one <path data-c="US"> per country), fetched once and coloured here from the counts the page
// sends (`data-counts`, `{"US": 412, …}`). A country with more titles is darker in the site's
// primary colour — on a log scale, so one country with hundreds does not leave the rest blank —
// and the ones with none stay a faint outline in the text colour (white on the banner's card,
// the page's ink in the sheet).
//
// `data-interactive` (the big map in the sheet): the country under the pointer is outlined and
// named with its count in a label that follows the pointer; a click on one with titles opens
// `data-href` + its code (the watch history filtered to it). Countries with titles are links for
// the keyboard too (Tab, Enter). On touch the first tap names a country, the second opens it.
const cache = {}

function load(src) {
  cache[src] ||= fetch(src).then((r) => (r.ok ? r.text() : Promise.reject(r.status)))
  return cache[src]
}

const plural = (n) => `${n} ${n === 1 ? "title" : "titles"}`

export const WorldMap = {
  mounted() { this.draw() },
  updated() { this.draw() },

  async draw() {
    const el = this.el
    let counts = {}
    try { counts = JSON.parse(el.dataset.counts || "{}") } catch {}
    let svg
    try { svg = await load(el.dataset.src) } catch { return }
    if (!el.querySelector("svg")) el.innerHTML = svg
    const live = el.hasAttribute("data-interactive")
    const max = Math.max(1, ...Object.values(counts))
    for (const p of el.querySelectorAll("path[data-c]")) {
      const n = counts[p.dataset.c] || 0
      const t = p.querySelector("title")
      if (t && !p.dataset.name) p.dataset.name = t.textContent
      const name = p.dataset.name || p.dataset.c
      p.dataset.n = n
      if (n > 0) {
        // 0.25 for one title, 1 for the most watched country.
        const k = 0.25 + 0.75 * (Math.log(n + 1) / Math.log(max + 1))
        p.setAttribute("fill", `color-mix(in oklab, var(--color-primary) ${Math.round(k * 100)}%, transparent)`)
        p.setAttribute("stroke", "color-mix(in oklab, currentColor 35%, transparent)")
      } else {
        p.setAttribute("fill", "color-mix(in oklab, currentColor 8%, transparent)")
        p.setAttribute("stroke", "color-mix(in oklab, currentColor 18%, transparent)")
      }
      p.setAttribute("stroke-width", "0.5")
      if (live) {
        // The label does the naming here; a native tooltip would say it a second time.
        t?.remove()
        if (n > 0) {
          p.setAttribute("tabindex", "0")
          p.setAttribute("role", "link")
          p.setAttribute("aria-label", `${name}: ${plural(n)}`)
        } else {
          p.removeAttribute("tabindex")
          p.removeAttribute("role")
        }
      } else if (t) {
        t.textContent = n > 0 ? `${name}: ${plural(n)}` : name
      }
    }
    if (live && !this.wired) this.wire()
  },

  wire() {
    this.wired = true
    const el = this.el
    const tip = document.createElement("div")
    tip.className = "world-tip"
    tip.hidden = true
    el.appendChild(tip)
    this.tip = tip

    const country = (e) => e.target.closest?.("path[data-c]")
    const open = (p) => {
      if (+p.dataset.n > 0) this.js().navigate(el.dataset.href + p.dataset.c)
    }

    el.addEventListener("pointermove", (e) => {
      if (e.pointerType === "touch") return
      const p = country(e)
      p ? this.show(p, e.clientX, e.clientY) : this.hide()
    })
    // A finger "leaves" every time it lifts; only a mouse leaving means the pointer went away.
    el.addEventListener("pointerleave", (e) => { if (e.pointerType !== "touch") this.hide() })
    el.addEventListener("click", (e) => {
      const p = country(e)
      if (!p) return this.hide()
      // A finger has no hover: the first tap names the country, a second tap on it opens it.
      if (this.lastPointer === "touch" && this.armed !== p) {
        this.armed = p
        const r = p.getBoundingClientRect()
        return this.show(p, r.left + r.width / 2, r.top + r.height / 2)
      }
      open(p)
    })
    el.addEventListener("pointerdown", (e) => { this.lastPointer = e.pointerType })
    el.addEventListener("focusin", (e) => {
      const p = country(e)
      if (!p) return
      const r = p.getBoundingClientRect()
      this.show(p, r.left + r.width / 2, r.top + r.height / 2)
    })
    el.addEventListener("focusout", () => this.hide())
    el.addEventListener("keydown", (e) => {
      const p = country(e)
      if (p && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); open(p) }
    })
  },

  show(p, x, y) {
    if (this.hot !== p) {
      this.hot?.classList.remove("is-hot")
      p.classList.add("is-hot")
      // Its outline is a copy drawn over everything (moving the country itself to the top would
      // take the focus off it).
      if (!this.ring) {
        this.ring = document.createElementNS("http://www.w3.org/2000/svg", "path")
        this.ring.setAttribute("class", "world-ring")
        this.el.querySelector("svg").appendChild(this.ring)
      }
      this.ring.setAttribute("d", p.getAttribute("d"))
      this.ring.style.display = ""
      this.hot = p
      const n = +p.dataset.n
      this.tip.innerHTML = ""
      const b = document.createElement("b")
      b.textContent = p.dataset.name || p.dataset.c
      const s = document.createElement("span")
      s.textContent = n > 0 ? plural(n) : "nothing yet"
      this.tip.append(b, s)
    }
    const box = this.el.getBoundingClientRect()
    this.tip.hidden = false
    // Above the pointer, kept inside the map.
    const w = this.tip.offsetWidth, h = this.tip.offsetHeight
    const left = Math.min(Math.max(x - box.left - w / 2, 4), box.width - w - 4)
    const top = y - box.top - h - 14
    this.tip.style.transform = `translate(${left}px, ${top < 4 ? y - box.top + 18 : top}px)`
  },

  hide() {
    this.hot?.classList.remove("is-hot")
    if (this.ring) this.ring.style.display = "none"
    this.hot = null
    this.armed = null
    if (this.tip) this.tip.hidden = true
  },
}
