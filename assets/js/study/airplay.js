// AirPlay, from Safari: a button in the bar that shows when a device is in reach, and what the
// page does while the picture is on the TV.
//
// Safari's API is its own (`webkitShowPlaybackTargetPicker`, the availability and the
// wireless-target events); other browsers have no AirPlay at all, so without it the button stays
// hidden. The receiver plays the video element's address itself: our stream addresses carry a
// signed token for that (RokiWeb.StreamToken), and what it draws of the subtitles are the
// renditions listed in the playlist — the element's own text tracks — not the lines this page
// draws, so `remoteSubtitleTrack` finds the one that is the studied track.

export function bindAirPlay(root, video, stage, study) {
  const btn = root.querySelector("[data-role=airplay]")
  if (!btn) return null
  const note = stage ? stage.querySelector("[data-role=airplay-note]") : null
  const able = typeof video.webkitShowPlaybackTargetPicker === "function" && typeof window !== "undefined" && "WebKitPlaybackTargetAvailabilityEvent" in window
  if (!able) { btn.hidden = true; return null }

  video.addEventListener("webkitplaybacktargetavailabilitychanged", (e) => { btn.hidden = e.availability !== "available" })
  btn.addEventListener("click", () => { try { video.webkitShowPlaybackTargetPicker() } catch (e) {} })

  const reflect = () => {
    const on = !!video.webkitCurrentPlaybackTargetIsWireless
    btn.setAttribute("aria-pressed", String(on))
    btn.classList.toggle("btn-primary", on)
    if (stage) { if (on) stage.dataset.airplay = "true"; else delete stage.dataset.airplay }
    if (note) note.hidden = !on
    if (study && study.setWireless) study.setWireless(on)
  }
  video.addEventListener("webkitcurrentplaybacktargetiswirelesschanged", reflect)
  reflect()
  return {reflect}
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
