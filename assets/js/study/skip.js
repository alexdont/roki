// The "Skip intro" / "Skip credits" / "Next episode" button over the picture. Where to skip comes
// from AniSkip (anime, sent by the page as `skips`) or else from the gaps in the dialogue of a
// loaded subtitle track (`findSkips` in cues.js). It shows only while the playhead is inside an
// opening or credits, and only when `study.skip !== false` (the player's setting).
import {findSkips, aniskipSkips, skipAt} from "./cues.js"

export function bindSkip(root, video, study) {
  const btn = root.querySelector("[data-role=skip]")
  if (!btn) return
  const label = btn.querySelector("[data-role=skip-label]")
  let key = ""
  let skips = []
  let shown = null
  // The button greets the intro, then steps aside so it never sits over the picture of someone who
  // wants to watch it; a pointer going down towards the controls brings it back (`wake`).
  const FADE_MS = 3500
  let fadeTimer = 0
  const fadeSoon = (ms = FADE_MS) => {
    clearTimeout(fadeTimer)
    fadeTimer = setTimeout(() => {
      if (btn.matches(":hover, :focus-visible")) return fadeSoon(1500)
      btn.dataset.faded = "true"
    }, ms)
  }
  const wake = () => {
    if (btn.hidden) return
    delete btn.dataset.faded
    fadeSoon()
  }

  // The track to read the gaps from: the studied one, unless it is still being read out of the
  // release on this device (it grows as the film plays, so its end is not its end) and another
  // complete one is on.
  const source = () => {
    const layers = [study.p, ...(study.extras || [])].filter((l) => l && l.cues && l.cues.length >= 10)
    return layers.find((l) => !l.growing) || layers[0] || null
  }

  const compute = (total) => {
    const layer = source()
    const k = [JSON.stringify(study.aniskip || []), layer ? layer.cues.length : 0, layer?.cues[0]?.start, layer?.growing, study.offset || 0, Math.round(total)].join("|")
    if (k === key) return
    key = k
    const fromAniskip = aniskipSkips(study.aniskip, total)
    const fromLines = layer ? findSkips(layer.cues, total, study.offset || 0, {complete: !layer.growing}) : []
    // AniSkip's opening or ending wins over the guess of the same kind.
    skips = [...fromAniskip, ...fromLines.filter((s) => !fromAniskip.some((a) => a.kind === s.kind))]
  }

  const update = () => {
    const total = study.total()
    compute(total)
    const now = study.abs()
    let s = study.skip === false || !(total > 0) ? null : skipAt(skips, now)
    // Credits that run to the end: for a series that is the next episode; a film has nothing after.
    const next = s && s.tail && study.nextBtn && !study.nextBtn.hidden
    if (s && s.tail && !next) s = null
    if (s !== shown) {
      shown = s
      btn.hidden = !s
      clearTimeout(fadeTimer)
      delete btn.dataset.faded
      if (s) {
        fadeSoon()
        label.textContent = next ? "Next episode" : s.kind === "intro" ? "Skip intro" : "Skip credits"
        btn.dataset.kind = next ? "next" : s.kind
      }
    }
  }

  btn.addEventListener("click", (e) => {
    e.stopPropagation()
    const s = shown
    if (!s) return
    if (btn.dataset.kind === "next") study.nextBtn.click()
    else study.seekAbs(s.to)
    btn.hidden = true
    shown = null
  })

  // Towards the controls (the lower third of the picture) or a tap: here it is again.
  root.addEventListener("pointermove", (e) => {
    if (btn.hidden || !btn.dataset.faded) return
    const r = root.getBoundingClientRect()
    if (e.clientY > r.top + r.height * 0.66) wake()
  })
  root.addEventListener("pointerdown", wake)
  btn.addEventListener("focus", wake)

  for (const ev of ["timeupdate", "seeked", "durationchange"]) video.addEventListener(ev, update)
  study.refreshSkip = () => { key = ""; shown = undefined; update() }
}
