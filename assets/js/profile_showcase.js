// The profile's showcase (ProfileLive, `#showcase`; the profile lab's design made real):
//
// - 3D or Simple, chosen per device and kept for every profile (`localStorage["roki:profile:view"]`;
//   when nothing is kept, Simple for a device without WebGL, with reduced motion or a small one).
//   Simple is the server's page as drawn: posters in rows. 3D loads /vendor/profile3d.js (three.js
//   and the globe, ~700 KB, never fetched for Simple), which draws rings of cases into the
//   `[data-stage]` slots, the globe into `[data-globe]` and piles of cases into `[data-piles]`.
// - A title opens full screen: the poster (Simple) or its case turning to you and opening (3D),
//   what it is on the right — asked of the server when opened (`item_details`) — and the way to its
//   page. A click anywhere away from it, Esc or × closes it.
const KEY = "roki:profile:view"
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c])

function chosenView() {
  try { const v = localStorage.getItem(KEY); if (v === "3d" || v === "simple") return v } catch {}
  const gl = (() => { try { const c = document.createElement("canvas"); return !!(c.getContext("webgl2") || c.getContext("webgl")) } catch { return false } })()
  const weak = (navigator.deviceMemory && navigator.deviceMemory <= 2) || (navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 2)
  return !gl || weak || matchMedia("(prefers-reduced-motion: reduce)").matches ? "simple" : "3d"
}

let threeMod = null
// A name in a variable, so the bundler leaves it alone: the browser fetches it, only for 3D.
const THREE_URL = "/vendor/profile3d.js"
const load3d = () => (threeMod ||= import(THREE_URL))

// Manga sources label their facts their own way ("Year Published: …", "This is ON-GOING
// series", "Written By: X, Illustrated By: Y"): the plain facts.
function tidy(d) {
  const o = { ...d }
  if (o.year && !/\d{4}/.test(o.year)) o.year = null
  else if (o.year) o.year = String(o.year).match(/\d{4}/)[0]
  if (o.status) {
    const st = String(o.status).toLowerCase()
    o.status = /on-?going|publishing|releasing/.test(st) ? "Ongoing" : /complete|finished/.test(st) ? "Completed" : /hiatus/.test(st) ? "On hiatus" : o.status
  }
  if (o.authors) o.authors = [...new Set(o.authors.flatMap((a) => String(a).split(/,|;|\band\b/)).map((a) => a.replace(/^\s*(written|illustrated|art|story)\s*by\s*:?\s*/i, "").trim()).filter(Boolean))]
  return o
}

export const ProfileShowcase = {
  mounted() {
    this.view = chosenView()
    this.el.dataset.view = this.view
    this.paintSwitch()
    this.el.addEventListener("click", (e) => {
      const b = e.target.closest?.("#showcase-switch [data-view]")
      if (b) return this.setView(b.dataset.view)
      const a = e.target.closest?.("[data-item]")
      if (!a || e.metaKey || e.ctrlKey || e.shiftKey || e.button) return
      e.preventDefault()
      try { this.open(JSON.parse(a.dataset.item), a.dataset.label) } catch {}
    })
    this.onKey = (e) => { if (e.key === "Escape") this.close() }
    window.addEventListener("keydown", this.onKey)
    this.sync()
  },
  updated() { this.sync() },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    this.close()
    this.unmount3d()
  },

  setView(v) {
    try { localStorage.setItem(KEY, v) } catch {}
    this.view = v; this.el.dataset.view = v; this.paintSwitch()
    if (v === "simple") this.unmount3d()
    this.sync()
  },
  paintSwitch() {
    for (const b of this.el.querySelectorAll("#showcase-switch [data-view]")) b.setAttribute("aria-pressed", String(b.dataset.view === this.view))
  },

  // 3D is drawn once the shelves and the recently watched are in, and again when what they show
  // changes (a shelf edited, the kind of ratings switched).
  sync() {
    if (this.view !== "3d") return
    const sig = [this.el.dataset.favorites, this.el.dataset.recent, this.el.dataset.ratings, this.el.dataset.countries,
      [...this.el.querySelectorAll("[data-stage],[data-globe],[data-piles]")].map((e) => e.id).join(",")].join("|")
    const kind = this.el.querySelector("[data-piles]")?.dataset.kind || "all"
    if (sig === this.sig) { if (kind !== this.kind) { this.kind = kind; this.three?.setKind(kind) } return }
    if (this.el.dataset.recent === "[]" && this.el.dataset.favorites === "{}") return
    this.sig = sig; this.kind = kind
    load3d().then((m) => {
      if (this.view !== "3d" || this.sig !== sig) return
      this.three = m.mount(this.el, { open: (it, label) => this.open(it, label) })
      this.three.setKind(kind)
      this.el.classList.add("is-3d")
    }).catch((e) => { console.warn("profile 3D", e); this.setView("simple") })
  },
  unmount3d() {
    this.el.classList.remove("is-3d")
    this.sig = null; this.three = null
    if (threeMod) threeMod.then((m) => m.destroy()).catch(() => {})
    for (const el of this.el.querySelectorAll("[data-stage],[data-globe],[data-piles]")) el.innerHTML = ""
  },

  // ── the opened view ──────────────────────────────────────────────────────────────────────
  open(it, label) {
    this.close()
    const vw = document.createElement("div")
    vw.className = "showcase-viewer"
    vw.innerHTML = `<div class="vstage"></div><aside class="vinfo"></aside><button type="button" class="vclose" aria-label="Close">×</button>`
    document.body.appendChild(vw); document.body.classList.add("showcase-open")
    this.vw = vw
    const stage = vw.querySelector(".vstage"), info = vw.querySelector(".vinfo")
    const href = it.href || (it.type === "movie" || it.type === "tv" ? `/title/${it.type}/${it.id}` : null)
    const draw = (d) => {
      d = tidy(d || {})
      const kind = { movie: "Film", tv: "Show", manga: "Manga" }[it.type] || "Title"
      const hm = (m) => m ? (m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`) : null
      const facts = [kind, d.year || it.year, it.type === "movie" ? hm(d.minutes) : null,
        d.seasons ? `${d.seasons} season${d.seasons === 1 ? "" : "s"}` : null, d.episodes ? `${d.episodes} episodes` : null,
        d.status && d.status !== "Released" ? d.status : null].filter(Boolean)
      const scores = [
        it.score ? `<span class="you">★ ${it.score} <small>yours</small></span>` : "",
        d.vote ? `<span>★ ${Number(d.vote).toFixed(1)} <small>TMDB</small></span>` : "",
        it.at ? `<span><small>watched</small> ${new Date(it.at * 1000).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" })}</span>` : "",
      ].join("")
      const row = (l, list) => list && list.length ? `<div class="vrow"><dt>${l}</dt><dd>${list.map(esc).join(", ")}</dd></div>` : ""
      info.innerHTML = `<div class="vlabel">${esc(label || "")}</div>
        <h2>${esc(it.title)}</h2>
        ${d.tagline ? `<p class="vtag">${esc(d.tagline)}</p>` : ""}
        <div class="vmeta">${facts.map((x) => `<span>${esc(x)}</span>`).join("")}</div>
        ${d.genres?.length ? `<div class="vgenres">${d.genres.map((g) => `<span>${esc(g)}</span>`).join("")}</div>` : ""}
        ${scores ? `<div class="vscores">${scores}</div>` : ""}
        ${d.overview ? `<p class="vover">${esc(d.overview)}</p>` : d.loading ? `<p class="vover vwait">…</p>` : ""}
        <dl class="vfacts">${row(it.type === "tv" ? "Created by" : "Directed by", d.directors)}${row("Starring", d.cast)}${row("Written by", d.authors)}${row(it.type === "tv" ? "On" : "Studio", it.type === "tv" ? d.networks : d.studios)}${row("From", d.countries)}</dl>
        ${href ? `<a class="vgo" href="${esc(href)}" data-phx-link="redirect" data-phx-link-state="push">Open on Roki →</a>` : ""}`
    }
    draw({ loading: true })
    this.pushEvent("item_details", { type: it.type, id: it.id, href: it.href }, (d) => { if (this.vw === vw) draw(d) })
    if (this.view === "3d") {
      load3d().then((m) => { if (this.vw === vw) this.vcase = m.viewerCase(stage, it) }).catch(() => {})
    } else if (it.poster) {
      stage.innerHTML = `<img src="${esc(it.poster.replace("/w342/", "/w500/"))}" alt="">`
    }
    // Away from it closes: not on the case or the poster, a link, the panel's words.
    vw.addEventListener("click", (e) => {
      const t = e.target
      if (t.closest(".vclose")) return this.close()
      if (t.closest("a")) return this.close(true)
      if (t.closest(".vinfo") && t !== info) return
      if (t.tagName === "IMG" && t.closest(".vstage")) return
      if (t.tagName === "CANVAS" && this.vcase) { if (this.vcase.wasDrag()) return; if (this.vcase.onCase(e)) return }
      this.close()
    })
  },
  close(keepScroll) {
    if (!this.vw) return
    this.vcase?.destroy(); this.vcase = null
    this.vw.remove(); this.vw = null
    document.body.classList.remove("showcase-open")
    void keepScroll
  },
}
