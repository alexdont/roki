// AirPlay, from Safari: a button in the bar, and what the page does while the picture is on the TV.
//
// Safari's API is its own (`webkitShowPlaybackTargetPicker`, the availability and the
// wireless-target events); other browsers have no AirPlay at all, so without it the button stays
// hidden. The receiver plays the video element's *address* itself — our stream addresses carry a
// signed token for that (RokiWeb.StreamToken) — which is why nothing assembled in the browser can
// be cast: the on-device player's MediaSource (and hls.js's) can only send the sound. So in device
// mode the button first asks the server to take the play over as a stream (`study.prepareAirPlay`),
// and the picker opens once that plays. What the TV draws of the subtitles are the renditions
// listed in the playlist — the element's own text tracks — not the lines this page draws, so
// `remoteSubtitleTrack` finds the one that is the studied track.

const TITLE = "Playing on AirPlay"
const SUB = "The AirPlay button brings it back here."

export function bindAirPlay(root, video, stage, study) {
  const btn = root.querySelector("[data-role=airplay]")
  if (!btn) return null
  const note = stage ? stage.querySelector("[data-role=airplay-note]") : null
  const title = note ? note.querySelector("[data-role=airplay-title]") : null
  const sub = note ? note.querySelector("[data-role=airplay-sub]") : null
  const able = typeof video.webkitShowPlaybackTargetPicker === "function" && typeof window !== "undefined" && "WebKitPlaybackTargetAvailabilityEvent" in window
  if (!able) { btn.hidden = true; return null }

  // Safari says when a device is in reach — but not while the device player has remote playback
  // off, so in that mode the button shows anyway (pressing it is what gets a stream ready).
  let avail = false
  const show = () => { btn.hidden = !(avail || (study && study.localMode) || btn.dataset.airplay) }
  video.addEventListener("webkitplaybacktargetavailabilitychanged", (e) => { avail = e.availability === "available"; show() })
  btn.addEventListener("click", () => {
    if (study && study.localMode && study.prepareAirPlay) { study.prepareAirPlay(); return }
    try { video.webkitShowPlaybackTargetPicker() } catch (e) {}
  })

  const say = (t, s) => { if (title) title.textContent = t; if (sub) sub.textContent = s }
  const reflect = () => {
    const on = !!video.webkitCurrentPlaybackTargetIsWireless
    btn.setAttribute("aria-pressed", String(on))
    btn.classList.toggle("btn-primary", on)
    if (stage) { if (on) stage.dataset.airplay = "true"; else delete stage.dataset.airplay }
    if (on) { delete btn.dataset.airplay; say(TITLE, SUB) }
    if (note && !btn.dataset.airplay) note.hidden = !on
    if (study && study.setWireless) study.setWireless(on)
  }
  video.addEventListener("webkitcurrentplaybacktargetiswirelesschanged", reflect)
  reflect()
  show()

  return {
    reflect,
    show,
    // The step before the picker, in device mode: "preparing" (the server is making a stream),
    // "ready" (press the button again), or nothing.
    prep(state) {
      if (state) btn.dataset.airplay = state; else delete btn.dataset.airplay
      if (state === "preparing") say("Getting the video ready for AirPlay", "The server is preparing a stream your TV can play. A moment…")
      else if (state === "ready") say("Ready for AirPlay", "Press the AirPlay button and pick your TV.")
      else say(TITLE, SUB)
      if (note) note.hidden = !state && !video.webkitCurrentPlaybackTargetIsWireless
      show()
    },
  }
}

// The playlist's subtitle rendition that is `want` (a track of the page's list: `url`, `lang`,
// `label`), among `tracks` (the element's TextTrackList), leaving out `ours` (the tracks this
// page put on the element itself). By name first; else by language, telling a track read out of
// the release from one fetched from a provider by the names the server gives those.
export function remoteSubtitleTrack(tracks, want, ours = new Set()) {
  if (!want) return null
  const list = []
  for (let i = 0; i < tracks.length; i++) {
    const t = tracks[i]
    if (!ours.has(t) && (t.kind === "subtitles" || t.kind === "captions")) list.push(t)
  }
  const lang = shortCode(want.lang)
  const same = list.filter((t) => lang && shortCode(t.language) === lang)
  const url = String(want.url || "")
  const fetched = /\/ext-/.test(url)
  const fromOs = /-os\d/.test(url)
  return (
    list.find((t) => want.label && t.label === want.label) ||
    (fetched && fromOs && same.find((t) => /OpenSubtitles/.test(t.label))) ||
    (fetched && same.find((t) => /\(/.test(t.label))) ||
    (!fetched && same.find((t) => !/\(/.test(t.label))) ||
    same[0] ||
    null
  )
}

const THREE = {jpn: "ja", eng: "en", fre: "fr", fra: "fr", spa: "es", ger: "de", deu: "de", ita: "it", por: "pt", rus: "ru", kor: "ko", chi: "zh", zho: "zh", dut: "nl", nld: "nl", pol: "pl", tur: "tr", ara: "ar", swe: "sv"}
export function shortCode(code) {
  const c = String(code || "").toLowerCase().split(/[-_]/)[0]
  return THREE[c] || (c.length === 2 ? c : "")
}
