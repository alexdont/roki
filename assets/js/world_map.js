// The profile's world map (ALEX-157): the outlines are a static SVG (`data-src`, Natural Earth,
// one <path data-c="US"> per country), fetched once and coloured here from the counts the page
// sends (`data-counts`, `{"US": 412, …}`). A country with more titles is darker in the site's
// primary colour — on a log scale, so one country with hundreds does not leave the rest blank —
// and the ones with none stay a faint outline. Hovering a country names it and says how many.
const cache = {}

function load(src) {
  cache[src] ||= fetch(src).then((r) => (r.ok ? r.text() : Promise.reject(r.status)))
  return cache[src]
}

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
    const max = Math.max(1, ...Object.values(counts))
    for (const p of el.querySelectorAll("path[data-c]")) {
      const n = counts[p.dataset.c] || 0
      const name = p.querySelector("title")?.dataset?.name || p.querySelector("title")?.textContent || ""
      const t = p.querySelector("title")
      if (t && !t.dataset.name) t.dataset.name = name
      if (n > 0) {
        // 0.25 for one title, 1 for the most watched country.
        const k = 0.25 + 0.75 * (Math.log(n + 1) / Math.log(max + 1))
        p.setAttribute("fill", `color-mix(in oklab, var(--color-primary) ${Math.round(k * 100)}%, transparent)`)
        p.setAttribute("stroke", "rgb(255 255 255 / 0.35)")
        if (t) t.textContent = `${t.dataset.name}: ${n} ${n === 1 ? "title" : "titles"}`
      } else {
        p.setAttribute("fill", "rgb(255 255 255 / 0.08)")
        p.setAttribute("stroke", "rgb(255 255 255 / 0.18)")
        if (t) t.textContent = t.dataset.name
      }
      p.setAttribute("stroke-width", "0.5")
    }
  },
}
