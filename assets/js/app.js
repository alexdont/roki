// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/roki"
import topbar from "../vendor/topbar"
import {StudySidebar} from "./study/sidebar"
import {setupPeek} from "./peek"
import {FillGrid, KeepPlace, placeParam} from "./fill_grid"
import {InfiniteScroll} from "./infinite_scroll"
import {MoodCarousel} from "./mood_carousel"
import {ShelfRow} from "./shelf_row"
import {startLocalPlayer} from "./study/local_player.js"
import {SubtitleScanner} from "./study/ebml_subs.js"
// The manga reader, as the app it came from loads it. PhoenixKit ships Fresco and Etcher of its
// own under the same globals, and they are not these: its build has no `viewerRegistry`, which
// is the contract the strip reader and the annotation layer bind through. These imports run
// after its bundle (that one is a plain script tag, this one is deferred), so the packaged
// versions are the ones the reader ends up using — the same ones it was built against.
import "../../deps/fresco/priv/static/fresco.js"
import "../../deps/fresco_strip/priv/static/fresco_strip.js"
import "../../deps/etcher/priv/static/etcher.js"
// The paged manga reader's panel zoom ("Smart panels" in Reading settings), which reads the
// meta the root layout writes. Its heavy lifting runs in /assets/js/panel_worker.js.
import "./panel_overlay"
// Custom tooltip slots for Etcher.
// - header: annotation author's display name. Etcher renders the
//   header slot in the same row as the delete (trash) button, so
//   the username and the action button share a line at the top of
//   the tooltip. Default would have fallen back to the shape kind
//   ("Rectangle"), which is meaningless to the reader.
// - body:   comment content only (no author repeat).
// - footer: untouched — default reads `metadata.subtitle` (the date).
window.Etcher = window.Etcher || {};
window.Etcher.tooltipSlots = Object.assign(window.Etcher.tooltipSlots || {}, {
  header: function(shape) {
    var m = shape.metadata || {};
    var esc = (window.Etcher && window.Etcher.escapeHtml) || ((s) => s);
    if (m.author_name) return esc(m.author_name);
    // Fall through to etcher's default (shape kind) when no author —
    // this also covers freshly drawn shapes before the composer posts.
    return null;
  }
})

const CommentBridge = {
  mounted() {
    this._openHandler = (e) => this.pushEvent("open_comment_modal", e.detail)
    this._updateHandler = (e) => this.pushEvent("annotation_updated", e.detail)
    this._closeHandler = () => this.pushEvent("close_comment_modal", {})
    this._loadedChaptersHandler = (e) => this.pushEvent("set_loaded_chapters", e.detail)
    window.addEventListener("open-comment-modal", this._openHandler)
    window.addEventListener("annotation-updated", this._updateHandler)
    window.addEventListener("close-comment-modal", this._closeHandler)
    window.addEventListener("etcher-loaded-chapters", this._loadedChaptersHandler)
    // Ping any active strip reader so it re-dispatches its loaded
    // chapters. The strip's initial dispatch may have fired before
    // this hook mounted; this handshake closes that race.
    window.dispatchEvent(new CustomEvent("etcher-bridge-ready"))
  },
  destroyed() {
    window.removeEventListener("open-comment-modal", this._openHandler)
    window.removeEventListener("annotation-updated", this._updateHandler)
    window.removeEventListener("close-comment-modal", this._closeHandler)
    window.removeEventListener("etcher-loaded-chapters", this._loadedChaptersHandler)
  }
}

const CommentModalScrollLock = {
  mounted() {
    this._prevOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"
  },
  destroyed() {
    document.body.style.overflow = this._prevOverflow || ""
  }
}

const CommentModalScroll = {
  mounted() {
    this._stop = (e) => e.stopPropagation()
    this.el.addEventListener("wheel", this._stop, { passive: true })
    this.el.addEventListener("touchstart", this._stop, { passive: true })
    this.el.addEventListener("touchmove", this._stop, { passive: true })
    this.el.addEventListener("touchend", this._stop, { passive: true })
    this.el.addEventListener("scroll", this._stop, { passive: true })
  },
  destroyed() {
    this.el.removeEventListener("wheel", this._stop)
    this.el.removeEventListener("touchstart", this._stop)
    this.el.removeEventListener("touchmove", this._stop)
    this.el.removeEventListener("touchend", this._stop)
    this.el.removeEventListener("scroll", this._stop)
  }
}

// For the player lab and the console.
window.rokiLocalPlayer = startLocalPlayer

// `?diag=1` on a page's address: kept for the tab the moment the page loads, before LiveView
// rewrites the address (the watch page patches in its source hash during the join, and bounces
// through the sources page when it has none). The player's hook reads it from here.
try { const q = new URLSearchParams(location.search); if (q.get("diag") === "1") sessionStorage.setItem("roki-diag", q.toString()) } catch (e) {}
window.rokiSubtitleScanner = SubtitleScanner

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// Which player this device uses. Remembered here, not on the server: a phone wants its own
// player (VLC), a laptop the page. The title page reads both from the socket params.
const platform = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  ? "ios"
  : /Android/.test(navigator.userAgent) ? "android" : /Mac/.test(navigator.platform) ? "mac" : "desktop"

const storedPlayer = () => {
  try { return localStorage.getItem("roki:player") } catch { return null }
}

// What a device with no remembered choice starts with: the page says (new accounts: the browser).
const defaultPlayer = () =>
  document.querySelector("meta[name='roki-player-default']")?.getAttribute("content") || "external"

const storedGrid = () => {
  try { return localStorage.getItem("roki:grid") } catch { return null }
}

// What this device decodes on its own, so the server can leave such video as it is instead of
// re-encoding it. Asked of the media engine, not guessed from the browser's name: Chrome says
// yes to HEVC only on a machine with a hardware decoder.
function deviceCaps() {
  // A video this device was once found unable to show (`player_failed`) is not asked for again.
  try { if (localStorage.getItem("roki:nodirect") === "1") return {hevc: false, av1: false, vp9: false, uhd: false} } catch {}
  try {
    const MS = window.ManagedMediaSource || window.MediaSource
    const ok = (t) => !!(MS && MS.isTypeSupported && MS.isTypeSupported(t))
    return {
      hevc: ok('video/mp4; codecs="hvc1.1.6.L120.B0"'),
      av1: ok('video/mp4; codecs="av01.0.08M.08"'),
      vp9: ok('video/mp4; codecs="vp09.00.40.08"'),
      // 4K: HEVC Main 10 at level 5.1, or AV1 at level 5.0. A device that decodes the codec at
      // 1080p but not at this level keeps the browser at 1080p.
      uhd: ok('video/mp4; codecs="hvc1.2.4.L153.B0"') || ok('video/mp4; codecs="av01.0.12M.08"'),
      // Whether this page can take a release apart and play it itself (assets/js/study/local_player.js).
      local: !!(MS && typeof WritableStream !== "undefined" && typeof AudioDecoder !== "undefined"),
    }
  } catch { return {} }
}

// A picture that fails to arrive (the connection dropped it, the server was busy fetching it)
// is asked for again, a few times, a little later — a grey poster should fill in by itself, not
// wait for a reload. `error` does not bubble, so it is caught on the way down.
const retryImage = (img, delay) => {
  const tries = Number(img.dataset.retries || 0)
  if (tries >= 4) return
  img.dataset.retries = String(tries + 1)
  const src = img.currentSrc || img.src
  setTimeout(() => {
    if (!img.isConnected) return
    img.removeAttribute("src")
    img.src = src
  }, delay * (tries + 1))
}

document.addEventListener("error", (e) => {
  const img = e.target
  if (!(img instanceof HTMLImageElement) || !img.src) return
  if (img.complete && img.naturalWidth > 0) return
  retryImage(img, 800)
}, true)

// The media library answers a size it has not made yet with a tiny grey placeholder (a 200,
// so no error): a picture that came back four pixels wide is asked for again a little later.
document.addEventListener("load", (e) => {
  const img = e.target
  if (!(img instanceof HTMLImageElement)) return
  if (img.naturalWidth <= 4 && img.naturalHeight <= 4 && /\/phoenix_kit\/file\//.test(img.currentSrc || img.src)) retryImage(img, 2500)
}, true)

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({
    _csrf_token: csrfToken,
    platform,
    player: storedPlayer() || defaultPlayer(),
    grid: storedGrid(),
    place: placeParam(),
    caps: deviceCaps(),
  }),
  hooks: {...window.PhoenixKitHooks, ...(window.FrescoHooks || {}), ...(window.EtcherHooks || {}), ...colocatedHooks, CommentBridge, CommentModalScrollLock, CommentModalScroll, StudySidebar, FillGrid, KeepPlace, InfiniteScroll, MoodCarousel, ShelfRow},
})

// A panel that appears below the fold on a phone (the player hand-off) scrolls itself into view.
window.addEventListener("roki:reveal", e => e.target.scrollIntoView({behavior: "smooth", block: "center"}))

// The rating slider: the word and the colour of the score under the thumb. Both come from the
// server, put on the sheet (`data-words`, `data-colors`): the words are laev's own list, and the
// colours are `RokiWeb.ScoreColor`'s — one scale, kept in one place, rather than a copy of its
// formula here to drift from it. Ten is "gold", which is not a colour on the ramp but a metal, and
// is drawn with the stylesheet's gold: a class on the number and the word, an attribute on the
// slider for its bar and thumb.
let SCORE_WORDS = {}
let SCORE_COLORS = {}
window.rokiScore = input => {
  const v = Number(input.value)
  const out = document.getElementById("rate-out")
  const word = document.getElementById("rate-word")
  const sheet = document.getElementById("rate-sheet")
  if (!Object.keys(SCORE_WORDS).length) {
    try { SCORE_WORDS = JSON.parse(sheet.dataset.words) } catch {}
  }
  if (!Object.keys(SCORE_COLORS).length) {
    try { SCORE_COLORS = JSON.parse(sheet.dataset.colors) } catch {}
  }
  const key = v % 1 === 0 ? String(v) : v.toFixed(1)
  const color = SCORE_COLORS[key] || SCORE_COLORS["7"] || ""
  const gold = color === "gold"

  out.textContent = key
  word.textContent = SCORE_WORDS[Math.min(10, Math.max(1, Math.round(v)))] || ""
  for (const el of [out, word]) {
    el.classList.toggle("rate-gold", gold)
    el.style.color = gold ? "" : color
  }
  if (gold) input.setAttribute("data-gold", "")
  else input.removeAttribute("data-gold")

  // The bar is the colour of the score, filled up to the thumb: the colour, and how far along it
  // is. (Where the slider starts is its own: 0.5 for a TMDB rating, 1 for MyAnimeList's.)
  const min = Number(input.min), max = Number(input.max)
  input.style.setProperty("--c", gold ? "var(--gold)" : color)
  input.style.setProperty("--p", String(Math.min(1, Math.max(0, (v - min) / (max - min)))))
}

// Play on an external player: the server found the release and says where to open it.
window.addEventListener("phx:roki:launch", e => { window.location.href = e.detail.url })

window.addEventListener("phx:roki:grid", e => {
  try { localStorage.setItem("roki:grid", e.detail.size) } catch {}
})

window.addEventListener("phx:roki:nodirect", () => { try { localStorage.setItem("roki:nodirect", "1") } catch {} })
window.addEventListener("phx:roki:player", e => {
  try { localStorage.setItem("roki:player", e.detail.mode) } catch {}
  document.documentElement.dataset.player = e.detail.mode
})

// Close a panel the server is done with (a search that found its season).
window.addEventListener("phx:roki:hide", e => {
  const el = document.getElementById(e.detail.id)
  if (el) el.style.display = "none"
})

// Scroll something inside a panel into view (the season list jumps to a year).
window.addEventListener("phx:roki:scrollto", e => {
  const el = document.getElementById(e.detail.id)
  const box = e.detail.within && document.getElementById(e.detail.within)
  if (el && box) box.scrollTop = el.offsetTop - box.offsetTop - 8
})

// Back and forward: grids restore the page count and scroll position they were left at.
window.addEventListener("popstate", () => { window.__rokiPopAt = Date.now() })

setupPeek()

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// A link to the page you are already on does nothing.
//
// Clicking "Movies" on the Movies page used to load it again, and clicking it quickly loaded it
// again and again. Only the nav links that opt in (`data-no-reload`) behave this way, and only for
// the exact address: /movies/603 is not /movies, and /manga?q=berserk is not /manga, so the same
// link still takes you back up from there. A modified click (new tab, new window) and a link that
// opens elsewhere are left alone.
//
// It is a capture-phase click handler rather than something in the layout because the reader's
// pages are plain controller pages with no LiveView to ask, and because LiveView's own link
// handler would otherwise navigate first. The link's own `phx-click` still runs, since on the
// menus it is what closes them.
document.addEventListener(
  "click",
  (e) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
    const link = e.target instanceof Element ? e.target.closest("a[href]") : null
    if (!link || !link.closest("[data-no-reload]") || link.target || link.hasAttribute("download")) return

    const here = new URL(window.location.href)
    const there = new URL(link.href, here)
    const bare = (path) => path.replace(/\/+$/, "") || "/"
    if (there.origin !== here.origin || bare(there.pathname) !== bare(here.pathname) || there.search !== here.search) return

    e.preventDefault()
    e.stopImmediatePropagation()

    // A menu the click was in should still close. Where there is a LiveView the link's own
    // `phx-click` does it; the reader's pages have none, so the panel is put away by hand
    // (nothing patches those pages, so nothing can put it back).
    const close = link.getAttribute("phx-click")
    if (close && window.liveSocket.main) window.liveSocket.execJS(link, close)
    else {
      const panel = link.closest("#account-pop, #mobile-nav")
      if (panel) panel.style.display = "none"
    }
  },
  true
)

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

