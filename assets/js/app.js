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
import {MenuExtras} from "./menu_extras"
import {hooks as colocatedHooks} from "phoenix-colocated/roki"
import topbar from "../vendor/topbar"
import {StudySidebar} from "./study/sidebar"
import {setupPeek} from "./peek"
import {FillGrid, placeParam} from "./fill_grid"

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
  try {
    const MS = window.ManagedMediaSource || window.MediaSource
    const ok = (t) => !!(MS && MS.isTypeSupported && MS.isTypeSupported(t))
    return {
      hevc: ok('video/mp4; codecs="hvc1.1.6.L120.B0"'),
      av1: ok('video/mp4; codecs="av01.0.08M.08"'),
      vp9: ok('video/mp4; codecs="vp09.00.40.08"'),
    }
  } catch { return {} }
}

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
  hooks: {...window.PhoenixKitHooks, ...colocatedHooks, StudySidebar, FillGrid, MenuExtras},
})

// A panel that appears below the fold on a phone (the player hand-off) scrolls itself into view.
window.addEventListener("roki:reveal", e => e.target.scrollIntoView({behavior: "smooth", block: "center"}))

// The rating slider: the word and the colour of the score under the thumb. The same scale as
// `score_word/1` and `score_color/1` in title_live.ex.
// The words come from laev, put on the sheet by the server (`data-words`).
let SCORE_WORDS = {}
function scoreColor(v) {
  const s = Math.min(10, Math.max(1, v))
  const [h, sat, l] = s <= 7 ? [(s - 1) / 6 * 130, 75, 46]
    : [130 - (s - 7) / 3 * 85, 75 + (s - 7) / 3 * 20, 46 + (s - 7) / 3 * 6]
  return `hsl(${Math.round(h)} ${Math.round(sat)}% ${Math.round(l)}%)`
}
window.rokiScore = input => {
  const v = Number(input.value)
  const color = scoreColor(v)
  const out = document.getElementById("rate-out")
  const word = document.getElementById("rate-word")
  out.textContent = v % 1 === 0 ? String(v) : v.toFixed(1)
  if (!Object.keys(SCORE_WORDS).length) {
    try { SCORE_WORDS = JSON.parse(document.getElementById("rate-sheet").dataset.words) } catch {}
  }
  word.textContent = SCORE_WORDS[Math.min(10, Math.max(1, Math.round(v)))] || ""
  out.style.color = word.style.color = color
  input.style.setProperty("--thumb", color)
}

// Play on an external player: the server found the release and says where to open it.
window.addEventListener("phx:roki:launch", e => { window.location.href = e.detail.url })

window.addEventListener("phx:roki:grid", e => {
  try { localStorage.setItem("roki:grid", e.detail.size) } catch {}
})

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

