// An animation for every mood over the home page's mood carousel (FeaturedLive, `#mood-fx`),
// reaching no further than halfway to the first row, and over the top of a mood's own page
// (MoodLive), a little lighter. The area it plays over is the element marked `data-fx-stage`; on
// a mood page the hook's element names its mood (`data-mood`) and its share (`data-amount`).
// Scrolling down past that area thins it out with the scroll, until it stops. One canvas on the page (what has landed scrolls with
// it), clicks pass through. Drawn at 30 frames a second, only while enough of the carousel is on
// screen and the tab is visible; scaled to the device (a quick drawing test when it starts, the
// browser's hints about cores and memory, and how frames actually go), and off with a note on a
// device too slow for it. Off for reduced motion.
//
// Each mood is an effect: `step(dt, amount, active)` and `draw(g, alpha)`; the one shown fades in,
// the one before fades out.
//
// The pointer is part of the weather (`fx.pointer`, `fx.pokes`): bubbles pop on it, the wind goes
// round it, rain is wiped away under it, fog parts for it, fireflies scatter from it, confetti and
// embers are stirred by it, lights lean to it, the heart quickens for it, the film is scratched by
// it, the camera follows it; a press (a tap, a click) is a poke — a burst, a blast, a thump, a
// shutter. Only the mood shown answers, and only while the pointer is over the area.

const rand = (a, b) => a + Math.random() * (b - a)
const pick = (xs) => xs[Math.floor(Math.random() * xs.length)]
const FPS = 30
// A bell curve around `at`, `w` wide: the shape of one beat.
const gauss = (p, at, w) => Math.exp(-(((p - at) / w) * ((p - at) / w)))
// How near the pointer a point is: 1 on it, 0 at `R` or beyond (or with no pointer about).
const near = (P, x, y, R) => { if (!P.on) return 0; const d = Math.hypot(x - P.x, y - P.y); return d < R ? 1 - d / R : 0 }
// The way from the pointer to a point, as a unit vector (straight up when they coincide).
const away = (P, x, y) => { const dx = x - P.x, dy = y - P.y, d = Math.hypot(dx, dy); return d < 0.01 ? [0, -1] : [dx / d, dy / d] }
// The pokes (presses) made since the last frame, for the mood shown.
const pokes = (fx, active) => (active ? fx.pokes.filter((k) => k.fresh) : [])

// ── pictures drawn once and stamped ────────────────────────────────────

function sprite(size, paint) {
  const c = document.createElement("canvas")
  c.width = c.height = size
  paint(c.getContext("2d"), size)
  return c
}

// A drop on glass: a clear body darker at its rim, light through its lower edge, a bright point.
const dropSprite = (kind) => sprite(64, (g) => {
  const cx = 32, cy = 32, R = 27
  const body = g.createRadialGradient(cx - 6, cy - 8, 2, cx, cy, R)
  if (kind === "blood") {
    body.addColorStop(0, "rgba(200,26,36,0.6)")
    body.addColorStop(0.65, "rgba(125,0,12,0.6)")
    body.addColorStop(0.94, "rgba(48,0,5,0.7)")
    body.addColorStop(1, "rgba(40,0,4,0)")
  } else {
    body.addColorStop(0, "rgba(255,255,255,0.22)")
    body.addColorStop(0.6, "rgba(205,218,238,0.09)")
    body.addColorStop(0.9, "rgba(0,0,0,0.38)")
    body.addColorStop(1, "rgba(0,0,0,0)")
  }
  g.fillStyle = body
  g.beginPath(); g.arc(cx, cy, R, 0, Math.PI * 2); g.fill()
  g.strokeStyle = kind === "blood" ? "rgba(255,90,90,0.28)" : "rgba(255,255,255,0.38)"
  g.lineWidth = 2.5
  g.beginPath(); g.arc(cx, cy, R - 4, 0.15 * Math.PI, 0.85 * Math.PI); g.stroke()
  g.fillStyle = kind === "blood" ? "rgba(255,215,215,0.6)" : "rgba(255,255,255,0.9)"
  g.beginPath(); g.ellipse(cx - 9, cy - 10, 5, 3.5, -0.6, 0, Math.PI * 2); g.fill()
})

// A soft round of light in a colour, brightest in the middle.
const glowSprite = (r, gr, b, core = 0) => sprite(64, (g) => {
  const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32)
  grad.addColorStop(0, `rgba(${Math.min(255, r + core)},${Math.min(255, gr + core)},${Math.min(255, b + core)},1)`)
  grad.addColorStop(0.25, `rgba(${r},${gr},${b},0.55)`)
  grad.addColorStop(1, `rgba(${r},${gr},${b},0)`)
  g.fillStyle = grad
  g.fillRect(0, 0, 64, 64)
})

// Out-of-focus light: an even disc with a slightly brighter rim.
const bokehSprite = (r, gr, b) => sprite(64, (g) => {
  const grad = g.createRadialGradient(32, 32, 0, 32, 32, 30)
  grad.addColorStop(0, `rgba(${r},${gr},${b},0.55)`)
  grad.addColorStop(0.8, `rgba(${r},${gr},${b},0.62)`)
  grad.addColorStop(0.95, `rgba(${r},${gr},${b},0.85)`)
  grad.addColorStop(1, `rgba(${r},${gr},${b},0)`)
  g.fillStyle = grad
  g.beginPath(); g.arc(32, 32, 30, 0, Math.PI * 2); g.fill()
})

// A soap bubble: almost clear, a rainbow rim, a window of light.
const bubbleSprite = () => sprite(96, (g) => {
  const rim = g.createLinearGradient(0, 0, 96, 96)
  rim.addColorStop(0, "rgba(120,220,255,0.75)")
  rim.addColorStop(0.35, "rgba(255,140,230,0.7)")
  rim.addColorStop(0.65, "rgba(255,235,120,0.7)")
  rim.addColorStop(1, "rgba(140,255,190,0.75)")
  const body = g.createRadialGradient(48, 48, 20, 48, 48, 45)
  body.addColorStop(0, "rgba(255,255,255,0.02)")
  body.addColorStop(1, "rgba(255,255,255,0.14)")
  g.fillStyle = body
  g.beginPath(); g.arc(48, 48, 44, 0, Math.PI * 2); g.fill()
  g.strokeStyle = rim
  g.lineWidth = 2.2
  g.stroke()
  g.fillStyle = "rgba(255,255,255,0.75)"
  g.beginPath(); g.ellipse(32, 30, 9, 5, -0.7, 0, Math.PI * 2); g.fill()
  g.fillStyle = "rgba(255,255,255,0.35)"
  g.beginPath(); g.ellipse(64, 68, 4, 2.5, -0.7, 0, Math.PI * 2); g.fill()
})

// A wisp of fog: soft lumps run together, every one of them inside the picture, so the wisp has
// no edge anywhere (a lump cut off at the side drew a hard line that looked like fog popping in).
const fogSprite = () => sprite(256, (g) => {
  for (let i = 0; i < 14; i++) {
    const r = rand(35, 70)
    const x = rand(8 + r, 248 - r), y = rand(Math.max(8 + r, 100), Math.min(248 - r, 156))
    const grad = g.createRadialGradient(x, y, 0, x, y, r)
    grad.addColorStop(0, "rgba(225,220,240,0.16)")
    grad.addColorStop(1, "rgba(225,220,240,0)")
    g.fillStyle = grad
    g.fillRect(0, 0, 256, 256)
  }
})

// A puff of fog: soft lumps gathered round the middle, nothing near the edge of the picture.
const puffSprite = () => sprite(256, (g) => {
  for (let i = 0; i < 7; i++) {
    const r = rand(62, 92), a = rand(0, Math.PI * 2), d = rand(0, 34)
    const x = 128 + Math.cos(a) * d, y = 128 + Math.sin(a) * d * 0.8
    const grad = g.createRadialGradient(x, y, 0, x, y, r)
    grad.addColorStop(0, "rgba(225,220,240,0.1)")
    grad.addColorStop(0.55, "rgba(225,220,240,0.05)")
    grad.addColorStop(1, "rgba(225,220,240,0)")
    g.fillStyle = grad
    g.fillRect(0, 0, 256, 256)
  }
})

// Film grain: specks light and dark.
const grainSprite = () => sprite(128, (g) => {
  const img = g.createImageData(128, 128)
  for (let i = 0; i < img.data.length; i += 4) {
    const on = Math.random() < 0.18
    const v = Math.random() < 0.5 ? 0 : 255
    img.data[i] = img.data[i + 1] = img.data[i + 2] = v
    img.data[i + 3] = on ? rand(10, 60) : 0
  }
  g.putImageData(img, 0, 0)
})

// ── the effects ────────────────────────────────────────────────────────

// Rain on glass (cry) and red rain (scared): streaks fall from the top of the page, some land on
// the carousel as drops that sit, swell, run down in fits leaving a trail, pull into each other's
// wet paths and merge, cross onto the first row and thin away.
const RAIN = {
  cry: {
    streak: "rgba(205,222,255,0.42)", width: 1.3, speed: [1250, 1650], len: [18, 34], rate: 85,
    stick: 0.32, sprite: "water", trail: "rgba(235,242,255,0.07)", splash: "rgba(225,236,255,0.55)",
    slide: 1, fadeInRow: 0.45, trailW: 0.5,
    // The drops that sit still: how often a runner leaves one behind (a second), how long one that
    // lands stays before drying (s), and how strongly they are drawn.
    residue: 2.2, still: [8, 18], stillAlpha: 1,
    // A running drop's body: clear water, darker at its edge, light down one side.
    rim: "rgba(0,0,0,0.3)", glint: "rgba(255,255,255,0.3)",
    lens: [[0, "rgba(255,255,255,0.2)"], [0.55, "rgba(205,218,238,0.08)"], [0.85, "rgba(0,0,0,0.22)"], [1, "rgba(0,0,0,0.38)"]],
    under: "rgba(235,242,255,0.38)", spark: "rgba(255,255,255,0.85)",
  },
  scared: {
    streak: "rgba(175,12,22,0.4)", width: 1.8, speed: [1050, 1400], len: [20, 38], rate: 72,
    stick: 0.38, sprite: "blood", trail: "rgba(95,0,8,0.32)", splash: "rgba(170,14,24,0.45)",
    slide: 0.65, fadeInRow: 0.22, trailW: 0.7,
    // Red dots sitting still were the loudest thing on the page: fewer, drying sooner, fainter.
    residue: 0.6, still: [3, 7], stillAlpha: 0.6,
    rim: "rgba(40,0,4,0.5)", glint: "rgba(255,120,120,0.18)",
    lens: [[0, "rgba(205,30,40,0.55)"], [0.6, "rgba(120,0,12,0.55)"], [1, "rgba(50,0,5,0.65)"]],
    under: null, spark: "rgba(255,210,210,0.55)",
  },
}

// A drop's own shape, for its life. The head's edge is a sum of a few slow waves of its own (so it
// is lumpy in its own way, not a ball pulled about); the tail bends in its own curve, is fuller on
// one side than the other, and on some has a bead of water partway up.
function makeShape() {
  const waves = []
  for (let i = 0; i < 4; i++) waves.push({k: 2 + i + Math.floor(Math.random() * 2), a: rand(-1, 1) * [0.2, 0.13, 0.08, 0.05][i], p: rand(0, 6)})
  return {
    len: rand(0.9, 3.4), full: rand(0.45, 1.3), neck: rand(0.1, 0.6),
    hw: rand(0.85, 1.12), hd: rand(0.8, 1.2), sag: rand(-0.3, 0.3), waves,
    bend: rand(-1, 1) * rand(0.2, 1.1), bendF: rand(0.7, 2.2), bendP: rand(0, 6),
    sideL: rand(0.65, 1.3), sideR: rand(0.65, 1.3),
    knot: Math.random() < 0.45 ? {at: rand(0.3, 0.7), size: rand(0.25, 0.55)} : null,
    lx: rand(-0.45, -0.1), ly: rand(-0.35, 0.05),
  }
}

// How far the edge of a lumpy round reaches at angle `t` (1 = its plain radius).
const lump = (sh, t) => {
  let k = 1
  for (const w of sh.waves) k += w.a * Math.sin(w.k * t + w.p)
  return k
}

function rain(fx, m) {
  const img = fx.sprites[m.sprite]
  let streaks = [], drops = [], bits = [], ghosts = [], acc = 0, wipes = [], lastWipe = null
  // What the wipe gathers: the water (or blood) of the drops it goes through collects under the
  // finger as one growing bead that rides along with it, and runs down as a drop when let go.
  let gather = null, stillFor = 0, strokeId = 0
  const LIFE = 1.1 // s: how long the film the finger leaves lasts before it has dried
  const max = () => Math.round((fx.phone ? 130 : 340) * Math.min(1, fx.amount() / 1.5))
  // Each drop its own shape, kept for its life: tail length, how full it stays before narrowing,
  // how wide its neck, a lean to one side, an uneven edge, a slightly squashed head.
  const drop = (x, y, r, life) => ({
    x, y, r, life, age: 0, vy: 0, sliding: false, stall: 0, wob: Math.random() * 6, trail: [], dead: false,
    shape: makeShape(),
  })

  const impact = (s, active) => {
    for (let i = 0; i < 3; i++) bits.push({x: s.x, y: s.hitY, vx: rand(-70, 70), vy: rand(-140, -40), life: rand(0.15, 0.3)})
    if (!active || Math.random() > m.stick) return
    const r = rand(2.2, 5.2) * (m.sprite === "blood" ? 1.1 : 1)
    for (const d of drops) {
      if (!d.dead && Math.abs(d.x - s.x) < d.r + r && Math.abs(d.y - s.hitY) < d.r + r) { d.r = Math.min(13, Math.hypot(d.r, r)); return }
    }
    if (drops.length < max()) drops.push(drop(s.x, s.hitY, r, rand(...m.still)))
  }

  return {
    busy: () => streaks.length + drops.length + bits.length + ghosts.length > 0,
    // For the console (`fxStats.effects.cry`): what the wipe holds.
    stats: () => ({drops: drops.length, tailPoints: wipes.length, strokes: new Set(wipes.map((w) => w.s)).size, bead: gather ? Math.round(gather.r * 10) / 10 : 0}),
    step(dt, amount, active) {
      if (active) {
        acc += m.rate * (fx.W / 1000) * (amount / 1.5) * dt
        while (acc >= 1) {
          acc -= 1
          const v = rand(...m.speed)
          const toRow = false
          streaks.push({
            x: rand(-40, fx.W), y: rand(-220, -10), v, vx: v * 0.06, len: rand(...m.len),
            hitY: toRow ? rand(fx.rowTop, fx.rowTop + (fx.rowBottom - fx.rowTop) * 0.6) : rand(fx.carTop + 80, fx.carBottom - 20),
          })
        }
      }
      for (const s of streaks) { s.y += s.v * dt; s.x += s.vx * dt; if (s.y >= s.hitY) { s.done = true; impact(s, active) } }
      streaks = streaks.filter((s) => !s.done)

      // Wiping: the pointer moving over the glass clears a finger's width under its path — still
      // drops gone, a runner gone with what was left of it, wet trails cut off above the wipe —
      // and gathers their water: the bead under the finger grows with every drop it takes, and
      // leaks a little behind it once it is big. Let go (the finger stops, or lifts), it runs down
      // the glass as one drop with all it gathered. A faint smear is left, drying. New rain lands.
      const P = fx.pointer
      const wiping = active && P.on && P.speed > 40
      if (wiping) {
        // The finger's width is what it is; what it leaves is thick where it moved slowly and thin
        // where it went fast (`k`, the share of the width the film has at that point).
        const r = 12, k = Math.max(0.28, Math.min(1, 1 - (P.speed - 140) / 1300))
        // A stroke after a pause is a new one, drawn as its own shape, never joined to the last
        // (which is left to dry). By time, never by distance: a fast hand is far from its last
        // point every frame, and that is one stroke.
        const fresh = !lastWipe || P.t - lastWipe.t > 0.3
        if (fresh) strokeId++
        const from = fresh ? {x: P.x, y: P.y} : lastWipe
        // The way the hand went this frame: through every move it made, not a line from the last
        // frame's place to this one's (a fast circle would be a dozen straight chords).
        const way = [from, ...P.path.filter((q) => Math.hypot(q.x - from.x, q.y - from.y) > 0.5), {x: P.x, y: P.y}]
        const inside = (w, p) => Math.hypot(p.x - w.x, p.y - w.y) < w.r
        const cut = (pts, w) => { let i = pts.length - 1; while (i >= 0 && !inside(w, pts[i])) i--; return i < 0 ? pts : pts.slice(i + 1) }
        if (!gather) gather = {x: P.x, y: P.y, vol: 0, trail: [], shape: makeShape(), wob: rand(0, 6)}
        stillFor = 0
        const sp = Math.max(1, P.speed), fwx = P.vx / sp, fwy = P.vy / sp
        const laid = []
        for (let v = 1; v < way.length; v++) {
          const a = way[v - 1], c = way[v]
          const dist = Math.hypot(c.x - a.x, c.y - a.y), steps = Math.max(1, Math.ceil(dist / 6))
          for (let i = 1; i <= steps; i++) laid.push({x: a.x + ((c.x - a.x) * i) / steps, y: a.y + ((c.y - a.y) * i) / steps, r, k, life: LIFE, s: strokeId})
        }
        for (const w of laid) {
          wipes.push(w)
          for (const d of drops) {
            if (d.dead) continue
            if (Math.hypot(d.x - w.x, d.y - w.y) < w.r + d.r * 0.5) {
              if (d.sliding && d.trail.length > 1) ghosts.push({pts: d.trail, r: d.r, life: 0.7})
              gather.vol += d.r * d.r
              d.dead = true
              continue
            }
            if (d.trail.length) d.trail = cut(d.trail, w)
          }
          for (const t of ghosts) t.pts = cut(t.pts, w)
          // A finger does not take everything with it: specks of water are left in the band behind
          // it, here and there, and now and then a bead big enough to see.
          if (Math.random() < 0.2 && drops.length < max() * 1.3) {
            const back = r + 3, side = rand(-0.7, 0.7) * r
            drops.push(drop(w.x - fwx * back - fwy * side, w.y - fwy * back + fwx * side, Math.random() < 0.15 ? rand(1.6, 2.4) : rand(0.7, 1.4), rand(4, 9)))
          }
        }
        ghosts = ghosts.filter((t) => t.pts.length > 1)
        // The bead rides just behind the finger, on the side it came from.
        const R = gather.r = Math.min(14, Math.sqrt(gather.vol) * 0.95)
        gather.x = P.x - (P.vx / sp) * R * 0.6
        gather.y = P.y - (P.vy / sp) * R * 0.6
        if (R > 6 && Math.random() < dt * (R - 5) * 1.2 && drops.length < max() * 1.3) {
          drops.push(drop(gather.x + rand(-2, 2), gather.y + rand(-2, 2), rand(1, 2.2), rand(...m.still)))
          gather.vol = Math.max(0, gather.vol - 3)
        }
        lastWipe = {x: P.x, y: P.y, t: P.t}
      } else {
        lastWipe = null
        if (gather) stillFor += dt
        // Let go: what was gathered becomes a drop, running from where the finger left it.
        if (gather && (stillFor > 0.2 || !P.on || !active)) {
          const R = Math.min(13, Math.sqrt(gather.vol) * 0.95)
          if (R >= 1.2) {
            const d = drop(gather.x, gather.y, R, rand(...m.still) + 6)
            d.sliding = R > 3.2
            // Its tail grows as it runs: the sideways track of the wipe is the smear's to fade.
            d.trail = []
            d.shape = gather.shape
            drops.push(d)
          }
          gather = null
        }
      }
      // The film the finger leaves lasts LIFE seconds wherever it was laid: the tail is what the
      // last second of movement left, long after a fast sweep, short after a slow one, and dries
      // from its far end in once the finger has stopped.
      for (const w of wipes) w.life -= dt
      wipes = wipes.filter((w) => w.life > 0)
      drops = drops.filter((d) => !d.dead)

      const n = drops.length
      for (let i = 0; i < n; i++) {
        const d = drops[i]
        if (d.dead) continue
        d.age += dt
        d.life -= dt
        if (!d.sliding) {
          if (d.r > 4.2 && Math.random() < dt * (d.r - 3.8) * 0.3) d.sliding = true
          continue
        }
        if (d.stall > 0) d.stall -= dt
        else {
          const speed = (18 + (d.r - 3.8) * 24) * m.slide
          d.vy += (speed - d.vy) * Math.min(1, dt * 4)
          d.y += d.vy * dt
          d.x += Math.sin(d.age * 0.6 + d.wob) * dt * (1.6 + Math.abs(d.shape.bend) * 2.5)
          if (Math.random() < dt * 0.6) { d.stall = rand(0.15, 0.9); d.x += rand(-1.2, 1.2) }
        }
        d.life = Math.max(d.life, 1.5) // a running drop runs out by shrinking, not by time
        const last = d.trail[d.trail.length - 1]
        if (!last || d.y - last.y > 3) { d.trail.push({x: d.x, y: d.y}); if (d.trail.length > 70) d.trail.shift() }
        if (Math.random() < dt * m.residue && drops.length < max() * 1.3) {
          drops.push(drop(d.x + rand(-1, 1), d.y - d.r, rand(0.9, 1.8), rand(3, 7)))
          d.r = Math.max(2, d.r - 0.06)
        }
        // What it runs into below, it takes up.
        for (let j = 0; j < n; j++) {
          const o = drops[j]
          if (o === d || o.dead || o.sliding) continue
          const dy = o.y - d.y
          if (dy > -1 && dy < d.r + o.r && Math.abs(o.x - d.x) < d.r + o.r) { d.r = Math.min(13, Math.hypot(d.r, o.r)); o.dead = true }
        }
        // Streams that meet run as one: drawn into another's wet path, merged on touching.
        for (let j = 0; j < n; j++) {
          const o = drops[j]
          if (o === d || o.dead || !o.sliding) continue
          const dx = o.x - d.x
          if (Math.abs(dx) > 14) continue
          if (Math.abs(dx) < (d.r + o.r) * 0.8 && Math.abs(o.y - d.y) < d.r + o.r) {
            const [big, small] = d.r >= o.r ? [d, o] : [o, d]
            big.r = Math.min(13, Math.hypot(big.r, small.r))
            big.stall = 0
            if (small.trail.length > 1) ghosts.push({pts: small.trail, r: small.r, life: 1.6})
            small.dead = true
            if (small === d) break
            continue
          }
          for (const p of o.trail) {
            if (Math.abs(p.y - d.y) < 4 && Math.abs(p.x - d.x) < d.r + 5) { d.x += (p.x - d.x) * Math.min(1, dt * 3); break }
          }
        }
        if (d.dead) continue
        if (d.y > fx.carBottom) d.r -= dt * m.fadeInRow * 1.6
        if (d.r < 1.2 || d.y > fx.rowBottom - 8) { d.sliding = false; d.life = Math.min(d.life, 0.6) }
      }
      for (const d of drops) if (d.life <= 0) d.dead = true
      drops = drops.filter((d) => !d.dead)
      for (const b of bits) { b.vy += 900 * dt; b.x += b.vx * dt; b.y += b.vy * dt; b.life -= dt }
      bits = bits.filter((b) => b.life > 0)
      for (const t of ghosts) t.life -= dt
      ghosts = ghosts.filter((t) => t.life > 0)
    },
    draw(g, alpha) {
      g.lineCap = "round"
      g.globalAlpha = alpha
      g.strokeStyle = m.streak
      g.lineWidth = m.width
      g.beginPath()
      for (const s of streaks) { g.moveTo(s.x, s.y); g.lineTo(s.x - (s.vx / s.v) * s.len, s.y - s.len) }
      g.stroke()
      g.strokeStyle = m.trail
      const line = (pts, r, a, x, y) => {
        g.globalAlpha = alpha * a
        g.lineWidth = Math.max(0.8, r * m.trailW)
        g.beginPath()
        g.moveTo(pts[0].x, pts[0].y)
        for (let i = 1; i < pts.length; i++) g.lineTo(pts[i].x, pts[i].y)
        if (x != null) g.lineTo(x, y)
        g.stroke()
      }
      // The smear behind the finger: the film it leaves, thickest right behind the fingertip
      // (and where the hand moved slowly), thinning and lightening back along the way it came as
      // it dries, to nothing — one soft shape, filled once (so a tail that turns or crosses itself
      // is one even tone), its depth a gradient from the tip to the end.
      const smearOf = (pts, withTip) => {
        const n = pts.length
        const tip = withTip && gather && gather.r > 1.2 ? gather : pts[n - 1]
        // From the tip back along the path: each point's full width (the finger's, less where it
        // moved fast) and how fresh it is (1 just laid, 0 dried).
        let seq = [tip], wid = [pts[n - 1].r * pts[n - 1].k], fresh = [1]
        for (let i = n - 1; i >= 0; i--) { seq.push(pts[i]); wid.push(pts[i].r * pts[i].k); fresh.push(pts[i].life / LIFE) }
        if (seq.length < 3) return
        // The path is straight chords between where the hand was each frame, which shows as corners
        // at speed: rounded off (each corner cut twice, four points for one), so the shape bends
        // smoothly; the widths and freshness go along with the points.
        for (let pass = 0; pass < 2; pass++) {
          const s2 = [seq[0]], w2 = [wid[0]], f2 = [fresh[0]]
          for (let i = 0; i < seq.length - 1; i++) {
            const a = seq[i], c = seq[i + 1]
            s2.push({x: a.x * 0.75 + c.x * 0.25, y: a.y * 0.75 + c.y * 0.25}, {x: a.x * 0.25 + c.x * 0.75, y: a.y * 0.25 + c.y * 0.75})
            w2.push(wid[i] * 0.75 + wid[i + 1] * 0.25, wid[i] * 0.25 + wid[i + 1] * 0.75)
            f2.push(fresh[i] * 0.75 + fresh[i + 1] * 0.25, fresh[i] * 0.25 + fresh[i + 1] * 0.75)
          }
          s2.push(seq[seq.length - 1]); w2.push(wid[wid.length - 1]); f2.push(fresh[fresh.length - 1])
          seq = s2; wid = w2; fresh = f2
        }
        const norms = []
        for (let i = 0; i < seq.length; i++) {
          const a = seq[Math.max(0, i - 1)], c = seq[Math.min(seq.length - 1, i + 1)]
          let nx = -(c.y - a.y), ny = c.x - a.x
          const nn = Math.hypot(nx, ny) || 1
          norms.push([nx / nn, ny / nn])
        }
        // Three layers, each one continuous shape at one alpha — so a pixel is covered at most
        // once by each, however the path turns or crosses itself, and there is no seam anywhere.
        // The film's depth along the tail comes from the layers dying out at different rates as the
        // film dries: the dense core first, the soft outer layer last, down to nothing.
        const [cr, cg, cb, top] = m.sprite === "blood" ? [120, 0, 8, 0.5] : [215, 228, 250, 0.17]
        for (const [scale, a, dry] of [[1, 0.45, 0.7], [0.66, 0.55, 1.3], [0.36, 0.7, 2.2]]) {
          g.beginPath()
          let started = false
          const w = (i) => wid[i] * scale * Math.pow(fresh[i], dry)
          for (let i = 0; i < seq.length; i++) { const [nx, ny] = norms[i], q = seq[i], k = w(i); started ? g.lineTo(q.x + nx * k, q.y + ny * k) : g.moveTo(q.x + nx * k, q.y + ny * k); started = true }
          for (let i = seq.length - 1; i >= 0; i--) { const [nx, ny] = norms[i], q = seq[i], k = w(i); g.lineTo(q.x - nx * k, q.y - ny * k) }
          g.closePath()
          g.globalAlpha = alpha * a
          g.fillStyle = `rgba(${cr},${cg},${cb},${top})`
          g.fill()
        }
      }
      // Each stroke its own shape, newest last; the newest carries the bead at its tip.
      for (let i = wipes.length; i > 0; ) {
        const id = wipes[i - 1].s
        let j = i
        while (j > 0 && wipes[j - 1].s === id) j--
        if (i - j > 1) smearOf(wipes.slice(j, i), id === strokeId)
        i = j
      }
      // Back to the trails' own faint colour: what follows draws with whatever is set.
      g.strokeStyle = m.trail
      for (const t of ghosts) line(t.pts, t.r, Math.min(1, t.life / 1.6))

      // The tapered body of a running drop: from its head up along the last stretch of its path,
      // as wide as the drop at the bottom and narrowing to a point, filled, with a darker rim
      // (and, for water, light down one side).
      // A running drop, drawn whole as one outline: its head at the bottom — each its own width,
      // depth and slight lopsidedness — rising into a tail that narrows (each at its own rate, to
      // its own neck, leaning a little) along the way it came. Shaded as a lens: dark at the rim,
      // light where it catches it, and for water a bright lower edge.
      const body = (d, a) => {
        const sh = d.shape
        const R = d.r * 0.92
        const hw = R * sh.hw, hd = R * sh.hd
        const len = d.r * sh.len * (m.sprite === "blood" ? 1.15 : 1)
        const pts = [{x: d.x, y: d.y, s: 0}]
        let s = 0
        for (let i = d.trail.length - 1; i >= 0 && s < len; i--) {
          const p = d.trail[i], q = pts[pts.length - 1]
          s += Math.hypot(q.x - p.x, q.y - p.y)
          pts.push({x: p.x, y: p.y, s: Math.min(s, len)})
        }
        const tail = pts.length >= 2 && s >= d.r * 0.4
        const kOf = (p) => p.s / Math.max(s, 1)
        // The tail's width on each side: narrowing at the drop's own rate, fuller on one side, and
        // swelling where it has a bead of water.
        const width = (p, side) => {
          const k = kOf(p)
          let w = hw * Math.pow(1 - k, sh.full) * (1 - sh.neck * k) * (side < 0 ? sh.sideL : sh.sideR)
          if (sh.knot) w += R * sh.knot.size * Math.exp(-(((k - sh.knot.at) / 0.1) ** 2)) * (1 - k * 0.5)
          // Where it meets the head, the two widths agree with the head's own edge.
          const join = Math.min(1, k * 4)
          return Math.max(0.3, w * join + hw * lump(sh, side < 0 ? Math.PI : 0) * (1 - join))
        }
        // The tail lies on the path the drop took, the trail's own line: any curve is the path's.
        const off = () => 0
        // Down at the bottom the head sags a little to one side, as weight pulls it.
        const headPt = (t) => {
          const k = lump(sh, t)
          return [d.x + Math.cos(t) * hw * k + sh.sag * hw * Math.sin(t) ** 3, d.y + Math.sin(t) * hd * k]
        }

        g.beginPath()
        if (tail) {
          for (const p of pts) g.lineTo(p.x + off(p) - width(p, -1), p.y)
          for (let i = pts.length - 1; i >= 1; i--) g.lineTo(pts[i].x + off(pts[i]) + width(pts[i], 1), pts[i].y)
        } else {
          for (let t = Math.PI; t <= Math.PI * 2 + 0.01; t += Math.PI / 10) { const k = lump(sh, t); g.lineTo(d.x + Math.cos(t) * hw * k, d.y + Math.sin(t) * hw * 0.8 * k) }
        }
        for (let t = 0; t <= Math.PI + 0.01; t += Math.PI / 18) g.lineTo(...headPt(t))
        g.closePath()

        g.globalAlpha = a
        const cx = d.x + sh.lx * hw, cy = d.y + sh.ly * hd
        const grad = g.createRadialGradient(cx, cy, 0, d.x, d.y + hd * 0.1, Math.max(hw, hd) * 1.2)
        for (const [at, c] of m.lens) grad.addColorStop(at, c)
        g.fillStyle = grad
        g.fill()
        g.strokeStyle = m.rim
        g.lineWidth = 0.8
        g.stroke()
        if (m.under) {
          g.strokeStyle = m.under
          g.lineWidth = Math.max(0.8, hd * 0.18)
          g.beginPath()
          for (let t = 0.35; t <= Math.PI - 0.35; t += Math.PI / 16) {
            const [x, y] = headPt(t)
            g.lineTo(d.x + (x - d.x) * 0.82, d.y + (y - d.y) * 0.82)
          }
          g.stroke()
        }
        g.fillStyle = m.spark
        g.beginPath()
        g.ellipse(cx, cy, Math.max(0.6, hw * 0.2), Math.max(0.5, hd * 0.14), -0.5 + sh.bend * 0.3, 0, Math.PI * 2)
        g.fill()
        if (tail && m.glint) {
          g.strokeStyle = m.glint
          g.lineWidth = Math.max(0.6, d.r * 0.18)
          g.beginPath()
          pts.forEach((p, i) => { if (i === 0) return; const x = p.x + off(p) - width(p, -1) * 0.45; i === 1 ? g.moveTo(x, p.y) : g.lineTo(x, p.y) })
          g.stroke()
        }
      }
      // A still drop big enough to see its shape: a lumpy round of its own, shaded like the runners.
      const blob = (d, a) => {
        const sh = d.shape, R = d.r * 0.95
        g.beginPath()
        for (let t = 0; t < Math.PI * 2; t += Math.PI / 12) {
          const k = lump(sh, t)
          g.lineTo(d.x + Math.cos(t) * R * sh.hw * k, d.y + Math.sin(t) * R * sh.hd * 0.9 * k)
        }
        g.closePath()
        g.globalAlpha = a
        const cx = d.x + sh.lx * R, cy = d.y + sh.ly * R
        const grad = g.createRadialGradient(cx, cy, 0, d.x, d.y, R * 1.2)
        for (const [at, c] of m.lens) grad.addColorStop(at, c)
        g.fillStyle = grad
        g.fill()
        g.strokeStyle = m.rim
        g.lineWidth = 0.7
        g.stroke()
        g.fillStyle = m.spark
        g.beginPath()
        g.ellipse(cx, cy, Math.max(0.5, R * 0.2), Math.max(0.4, R * 0.13), -0.5, 0, Math.PI * 2)
        g.fill()
      }
      for (const d of drops) if (d.trail.length > 1) line(d.trail, d.r, Math.min(1, d.life / 1.5), d.x, d.y)
      // The bead gathered under the finger.
      if (gather && gather.r > 1.2) blob(gather, alpha)
      // A running drop is a drop, not a bead on a line: the water gathers at the bottom under its own
      // weight and tapers up along the way it came into a thin neck, which the wet trail goes on from.
      for (const d of drops) if (d.sliding) body(d, alpha * Math.max(0, Math.min(1, d.life / 1.5)))
      // Still drops: the larger ones lumpy rounds of their own, the specks the plain stamped bead.
      for (const d of drops) {
        if (d.sliding) continue
        const a = alpha * Math.max(0, Math.min(1, d.life / 1.5)) * m.stillAlpha
        if (d.r >= 2.2) { blob(d, a); continue }
        g.globalAlpha = a
        const w = d.r * 2.4
        g.drawImage(img, d.x - w / 2, d.y - w / 2, w, w)
      }
      g.globalAlpha = alpha
      g.fillStyle = m.splash
      for (const b of bits) g.fillRect(b.x, b.y, 1.5, 1.5)
    },
  }
}

// Laugh: confetti raining gently from the top of the page, the paper fluttering (its width turns
// with it) as it drifts down, and gone at the line under the carousel.
function confetti(fx) {
  const COLORS = ["#ffd23f", "#ff6b6b", "#4ecdc4", "#ff9f1c", "#a78bfa", "#f472b6", "#7dd3fc"]
  let bits = [], acc = 0
  const piece = (x, y) => ({x, y, vy: rand(28, 48), w: rand(5, 9), h: rand(3, 5), c: pick(COLORS), rot: rand(0, 6), vr: rand(1.2, 3.2), sway: rand(0, 6), amp: rand(10, 22), life: 1, px: 0, py: 0})
  return {
    busy: () => bits.length > 0,
    step(dt, amount, active) {
      const cap = (fx.phone ? 120 : 320) * Math.min(1, amount / 1.5)
      if (active) {
        acc += 16 * (fx.W / 1000) * (amount / 1.5) * dt
        while (acc >= 1 && bits.length < cap) { acc -= 1; bits.push(piece(rand(0, fx.W), rand(-30, -5))) }
      }
      // The pointer stirs the paper near it (blown away from it, spinning); a poke is a burst.
      const P = fx.pointer
      for (const k of pokes(fx, active)) for (let i = 0; i < 26 && bits.length < cap + 60; i++) {
        const a = rand(0, Math.PI * 2), v = rand(140, 420), b = piece(k.x, k.y)
        b.px = Math.cos(a) * v; b.py = Math.sin(a) * v - 160; b.vr = rand(4, 9)
        bits.push(b)
      }
      for (const b of bits) {
        const n = active ? near(P, b.x, b.y, 110) : 0
        if (n) { const [ax, ay] = away(P, b.x, b.y); b.px += ax * n * 1100 * dt; b.py += ay * n * 800 * dt; b.rot += n * 9 * dt }
        b.px *= Math.pow(0.07, dt); b.py *= Math.pow(0.07, dt)
        b.sway += dt * 1.3
        b.x += Math.cos(b.sway) * b.amp * dt + b.px * dt
        b.y += (b.vy + b.py) * dt
        b.rot += b.vr * dt
        if (b.y > fx.rowBottom - 40) b.life -= dt * 1.5
      }
      bits = bits.filter((b) => b.life > 0 && b.y < fx.rowBottom && b.y > fx.carTop - 60)
    },
    draw(g, alpha) {
      for (const b of bits) {
        g.globalAlpha = alpha * Math.max(0, Math.min(1, b.life))
        g.fillStyle = b.c
        const w = b.w * Math.abs(Math.cos(b.rot)) + 0.6
        g.fillRect(b.x - w / 2, b.y - b.h / 2, w, b.h)
      }
    },
  }
}

// Fall in love: soft rose and warm lights out of focus, drifting up from the first row through the
// carousel, and a few small sparkles that come and go.
function bokeh(fx) {
  const imgs = [fx.sprites.rose, fx.sprites.blush, fx.sprites.warm]
  let lights = [], sparks = [], acc = 0
  return {
    busy: () => lights.length + sparks.length > 0,
    step(dt, amount, active) {
      const cap = (fx.phone ? 30 : 70) * Math.min(1, amount / 1.5)
      if (active) {
        acc += 4.5 * (fx.W / 1000) * (amount / 1.5) * dt
        while (acc >= 1 && lights.length < cap) {
          acc -= 1
          const life = rand(11, 17)
          lights.push({x: rand(0, fx.W), y: rand(fx.carBottom - 160, fx.rowTop + 30), r: rand(8, 30), vy: -rand(7, 16), sway: rand(0, 6), amp: rand(8, 22), img: pick(imgs), life, max: life, a: rand(0.55, 1), boost: 0})
        }
        if (sparks.length < cap / 3 && Math.random() < dt * 2) sparks.push({x: rand(0, fx.W), y: rand(fx.carTop + 60, fx.carBottom), r: rand(1.5, 3), life: 2.4, max: 2.4})
      }
      // The lights near the pointer lean towards it and glow up; sparkles follow its way.
      const P = fx.pointer
      if (active && P.on && P.speed > 60 && Math.random() < dt * 14) sparks.push({x: P.x + rand(-26, 26), y: P.y + rand(-26, 26), r: rand(1.5, 3), life: 1.4, max: 1.4})
      for (const k of pokes(fx, active)) for (let i = 0; i < 8; i++) sparks.push({x: k.x + rand(-40, 40), y: k.y + rand(-40, 40), r: rand(2, 3.5), life: 1.8, max: 1.8})
      for (const l of lights) {
        const n = active ? near(P, l.x + Math.sin(l.sway) * l.amp, l.y, 160) : 0
        l.boost += ((n ? Math.min(1, n * 1.4) : 0) - l.boost) * Math.min(1, dt * 2.5)
        if (n) { l.x += (P.x - Math.sin(l.sway) * l.amp - l.x) * n * dt * 0.9; l.y += (P.y - l.y) * n * dt * 0.9 }
        l.y += l.vy * dt; l.sway += dt * 0.35; l.life -= dt
      }
      lights = lights.filter((l) => l.life > 0 && l.y > fx.carTop - 40)
      for (const s of sparks) s.life -= dt
      sparks = sparks.filter((s) => s.life > 0)
    },
    draw(g, alpha) {
      g.globalCompositeOperation = "lighter"
      for (const l of lights) {
        const t = 1 - l.life / l.max
        g.globalAlpha = Math.min(1, alpha * l.a * Math.sin(Math.PI * t) * (1 + l.boost * 0.9))
        const x = l.x + Math.sin(l.sway) * l.amp, r = l.r * (1 + l.boost * 0.3)
        g.drawImage(l.img, x - r, l.y - r, r * 2, r * 2)
      }
      for (const s of sparks) {
        g.globalAlpha = alpha * Math.sin(Math.PI * (s.life / s.max))
        g.drawImage(fx.sprites.white, s.x - s.r * 3, s.y - s.r * 3, s.r * 6, s.r * 6)
      }
      g.globalCompositeOperation = "source-over"
    },
  }
}

// Feel the thrill: a heartbeat. The edges of the carousel darken red on each beat, and a heart
// trace runs across it; the heart speeds up as you stay, then calms and starts again.
function heartbeat(fx) {
  let t = 0, phase = 0, head = 0, excite = 0, thump = 0
  const step = 4
  let trace = []
  const beat = (p) => gauss(p, 0.05, 0.045) + 0.55 * gauss(p, 0.24, 0.05)
  // A heartbeat's line: a small bump, the sharp spike down-up-down, a slow wave after.
  const ecg = (p) =>
    0.12 * gauss(p, 0.0, 0.035) - 0.18 * gauss(p, 0.075, 0.01) +
    1 * gauss(p, 0.095, 0.012) - 0.3 * gauss(p, 0.115, 0.012) +
    0.22 * gauss(p, 0.32, 0.06)
  return {
    busy: () => false,
    step(dt, _amount, active) {
      if (!active) return
      t += dt
      // The pointer resting over it: the heart picks up over a few seconds, and settles when it
      // goes. A poke is a thump — a beat at once, the edges flushing with it.
      excite += ((fx.pointer.on ? 1 : 0) - excite) * Math.min(1, dt * 0.45)
      if (pokes(fx, true).length) { phase = 0; thump = 1 }
      thump *= Math.pow(0.03, dt)
      const bpm = 68 + 52 * Math.min(1, (t % 30) / 22) + 45 * excite
      const n = Math.ceil(fx.W / step)
      if (trace.length !== n) { trace = new Array(n).fill(0); head = 0 }
      const speed = Math.max(260, fx.W / 3.2)
      // The trace moves `speed` px a second; each new point is the heart at its own moment.
      const points = Math.max(1, Math.round((speed * dt) / step))
      const dp = (dt * bpm) / 60
      for (let i = 1; i <= points; i++) {
        head = (head + 1) % n
        trace[head] = ecg((phase + (dp * i) / points) % 1)
      }
      phase = (phase + dp) % 1
    },
    draw(g, alpha) {
      const top = fx.carTop, h = fx.carBottom - fx.carTop, cx = fx.W / 2, cy = top + h / 2
      const pulse = beat(phase)
      const R = Math.hypot(fx.W, h) / 2
      const v = g.createRadialGradient(cx, cy, R * 0.45, cx, cy, R)
      v.addColorStop(0, "rgba(150,0,25,0)")
      v.addColorStop(1, `rgba(150,0,25,${Math.min(0.85, 0.12 + 0.38 * pulse + 0.4 * thump)})`)
      g.globalAlpha = alpha
      g.fillStyle = v
      g.fillRect(0, top, fx.W, h)

      const n = trace.length
      if (!n) return
      // Low on the carousel. On a mood's page, where the search and filters sit low, in the open
      // space between the header (about 56 px) and the first line of words, sized to fit it.
      const room = fx.textTop - top - 56
      const base = fx.fixed ? top + 56 + room / 2 : top + h * 0.8
      const amp = fx.fixed ? Math.max(12, Math.min(45, room * 0.38)) : Math.min(70, h * 0.12)
      // The newest 70% of the sweep, brighter towards the head, never across the wrap.
      const span = Math.floor(n * 0.7), segs = 10
      g.lineJoin = "round"
      for (let s = 0; s < segs; s++) {
        const from = Math.floor((s * span) / segs), to = Math.floor(((s + 1) * span) / segs)
        g.beginPath()
        let started = false, prevI = -1
        for (let k = span - from; k >= span - to; k--) {
          const i = (head - k + n * 2) % n
          const x = i * step, y = base - trace[i] * amp
          if (!started || i < prevI) { g.moveTo(x, y); started = true } else g.lineTo(x, y)
          prevI = i
        }
        const a = (s + 1) / segs
        g.globalAlpha = alpha * a * 0.35
        g.strokeStyle = "rgba(255,60,90,1)"
        g.lineWidth = 5
        g.stroke()
        g.globalAlpha = alpha * a
        g.strokeStyle = "rgba(255,150,165,1)"
        g.lineWidth = 1.6
        g.stroke()
      }
    },
  }
}

// Blow things up: embers rising from the bottom of the carousel, and now and then a blast — a flash
// and a spray of sparks, some of which fall onto the first row.
function embers(fx) {
  let list = [], sparks = [], flashes = [], acc = 0, next = 1.2
  const blast = (x, y, amount) => {
    flashes.push({x, y, life: 0.45})
    const n = Math.round(rand(35, 55) * (amount / 1.5) * (fx.phone ? 0.5 : 1))
    for (let i = 0; i < n; i++) {
      const a = rand(0, Math.PI * 2), s = rand(180, 520)
      sparks.push({x, y, vx: Math.cos(a) * s, vy: Math.sin(a) * s - 120, life: rand(0.6, 1.4)})
    }
  }
  return {
    busy: () => list.length + sparks.length + flashes.length > 0,
    step(dt, amount, active) {
      const cap = (fx.phone ? 110 : 280) * Math.min(1, amount / 1.5)
      if (active) {
        acc += 26 * (fx.W / 1000) * (amount / 1.5) * dt
        while (acc >= 1 && list.length < cap) {
          acc -= 1
          list.push({x: rand(0, fx.W), y: fx.carBottom + rand(-10, 30), vx: rand(-15, 25), vy: -rand(50, 150), r: rand(1, 2.8), life: rand(2, 4.5), fl: rand(0, 6)})
        }
        if ((next -= dt) <= 0) {
          next = rand(3.5, 6.5)
          blast(rand(fx.W * 0.1, fx.W * 0.9), rand(fx.carTop + (fx.carBottom - fx.carTop) * 0.35, fx.carBottom - 60), amount)
        }
      }
      // A poke sets one off where it lands; the pointer stirs the embers near it up and away.
      for (const k of pokes(fx, active)) blast(k.x, k.y, amount)
      const P = fx.pointer
      for (const e of list) {
        const n = active ? near(P, e.x, e.y, 100) : 0
        if (n) { const [ax] = away(P, e.x, e.y); e.vx += ax * n * 420 * dt; e.vy -= n * 380 * dt }
        e.vx += rand(-40, 40) * dt; e.x += e.vx * dt; e.y += e.vy * dt; e.fl += dt * 12; e.life -= dt
      }
      list = list.filter((e) => e.life > 0)
      for (const s of sparks) { s.vy += 420 * dt; s.vx *= Math.pow(0.4, dt); s.x += s.vx * dt; s.y += s.vy * dt; s.life -= dt }
      sparks = sparks.filter((s) => s.life > 0 && s.y < fx.rowBottom)
      for (const f of flashes) f.life -= dt
      flashes = flashes.filter((f) => f.life > 0)
    },
    draw(g, alpha) {
      g.globalCompositeOperation = "lighter"
      for (const f of flashes) {
        g.globalAlpha = alpha * (f.life / 0.45) * 0.55
        const r = 160 + (0.45 - f.life) * 300
        g.drawImage(fx.sprites.fire, f.x - r, f.y - r, r * 2, r * 2)
      }
      for (const e of list) {
        g.globalAlpha = alpha * Math.min(1, e.life / 1.2) * (0.6 + 0.4 * Math.sin(e.fl))
        const r = e.r * 4
        g.drawImage(fx.sprites.ember, e.x - r, e.y - r, r * 2, r * 2)
      }
      g.lineCap = "round"
      g.strokeStyle = "rgba(255,220,140,1)"
      g.lineWidth = 1.4
      for (const s of sparks) {
        g.globalAlpha = alpha * Math.min(1, s.life / 0.5)
        g.beginPath(); g.moveTo(s.x, s.y); g.lineTo(s.x - s.vx * 0.025, s.y - s.vy * 0.025); g.stroke()
      }
      g.globalCompositeOperation = "source-over"
    },
  }
}

// Escape reality: fireflies. Each roams slowly in long lazy curves over the whole carousel, glows
// up gently, stays lit a while, and fades out again for a while, in its own time.
function fireflies(fx) {
  let flies = []
  const fly = () => ({x: rand(0, fx.W), y: rand(fx.carTop + 70, fx.rowBottom - 30), a: rand(0, Math.PI * 2), turn: 0, v: rand(6, 14), p: rand(0, 1), period: rand(6, 11), r: rand(5, 9), boost: 1})
  return {
    busy: () => false,
    step(dt, amount, active) {
      const want = Math.round((fx.phone ? 16 : 36) * Math.min(1.2, amount / 1.5))
      if (active) while (flies.length < want) flies.push(fly())
      if (flies.length > want) flies.length = want
      const P = fx.pointer
      for (const f of flies) {
        // Shy of the pointer: one it comes near turns away and darts off, then settles back into
        // its slow roaming. A poke startles every one within reach.
        let n = active ? near(P, f.x, f.y, 130) : 0
        for (const k of pokes(fx, active)) { const d = Math.hypot(f.x - k.x, f.y - k.y); if (d < 260) n = Math.max(n, 1 - d / 260) }
        if (n) {
          const want = Math.atan2(f.y - P.y, f.x - P.x)
          let diff = want - f.a; diff = Math.atan2(Math.sin(diff), Math.cos(diff))
          f.a += diff * Math.min(1, dt * 7 * n)
          f.boost = Math.max(f.boost, 1 + n * 6)
        }
        f.boost += (1 - f.boost) * Math.min(1, dt * 1.2)
        // The heading wanders a little at a time, so the path is a slow curve, not a jitter.
        f.turn += rand(-1, 1) * dt * 0.9
        f.turn *= Math.pow(0.5, dt)
        f.a += f.turn * dt
        // Kept over the carousel: past an edge, it turns back the long way round.
        if (f.y < fx.carTop + 60) f.a += (Math.PI / 2 - f.a) * dt * 0.6
        if (f.y > fx.rowBottom - 25) f.a += (-Math.PI / 2 - f.a) * dt * 0.6
        f.x += Math.cos(f.a) * f.v * f.boost * dt
        f.y += Math.sin(f.a) * f.v * f.boost * dt
        if (f.x < -30) f.x = fx.W + 30
        if (f.x > fx.W + 30) f.x = -30
        f.p = (f.p + dt / f.period) % 1
      }
    },
    draw(g, alpha) {
      g.globalCompositeOperation = "lighter"
      for (const f of flies) {
        // Dark for the first part of its cycle, then a slow glow up, a long hold, a slow fade.
        const q = f.p < 0.35 ? 0 : (f.p - 0.35) / 0.65
        const on = q <= 0 ? 0 : Math.sin(Math.PI * q) ** 0.8
        if (on < 0.02) continue
        g.globalAlpha = alpha * on
        const r = f.r * 3 * (0.85 + 0.15 * on)
        g.drawImage(fx.sprites.firefly, f.x - r, f.y - r, r * 2, r * 2)
      }
      g.globalCompositeOperation = "source-over"
    },
  }
}

// Solve a mystery: fog drifting slowly across the lower part of the carousel and on over the first
// row, a few motes of dust in it. Many soft puffs, each with a place of its own it drifts with: a
// hand through it pushes them aside, drags them a little along with it and sets them curling in
// eddies behind it (one way on one side of its path, the other way on the other), and thins the
// fog where it is; once the hand has gone the puffs drift back and the fog closes. A poke is a
// gust: a ring of fog thrown outward, swirling.
function fog(fx) {
  let puffs = [], motes = []
  const make = (i) => {
    const size = rand(240, 420)
    return {
      hx: rand(-size * 0.5, fx.W + size * 0.5), hy: rand(fx.carTop + (fx.carBottom - fx.carTop) * 0.3, fx.rowTop + 10),
      ox: 0, oy: 0, vx: 0, vy: 0, x: 0, y: 0, size, a: rand(0.3, 0.55), rot: rand(0, Math.PI * 2),
      spin: rand(-0.05, 0.05), vr: 0, thin: 0, wind: rand(4, 12) * (Math.random() < 0.5 ? 1 : -1),
      img: pick(fx.sprites.puffs), age: -i * 0.07,
    }
  }
  return {
    busy: () => false,
    stats: () => ({puffs: puffs.length, stirred: puffs.filter((p) => Math.hypot(p.vx, p.vy) > 5).length, thinned: puffs.filter((p) => p.thin > 0.1).length}),
    step(dt, amount, active) {
      const want = Math.round((fx.phone ? 32 : 70) * Math.min(1, amount / 1.5))
      puffs = puffs.filter((p) => !(p.out !== undefined && p.out <= 0))
      const kept = puffs.filter((p) => !p.out).length
      if (active && kept < want) for (let i = kept; i < want; i++) puffs.push(make(i - kept))
      puffs.forEach((p, i) => { if (i >= want && !p.out) p.out = 3 })
      const P = fx.pointer
      const on = active && P.on
      const ks = pokes(fx, active)
      for (const p of puffs) {
        if (p.out) p.out -= dt
        p.age += dt
        // Its own place drifts with the wind, round and round.
        p.hx += p.wind * dt
        if (p.hx > fx.W + p.size) p.hx = -p.size
        if (p.hx < -p.size) p.hx = fx.W + p.size
        // The hand: pushed out of its way, carried a little with it, curled round it, thinned.
        if (on) {
          const dx = p.x - P.x, dy = p.y - P.y, d = Math.hypot(dx, dy), R = 140 + p.size * 0.3
          if (d < R) {
            const n = 1 - d / R, n2 = n * n
            const [ax, ay] = away(P, p.x, p.y)
            const side = Math.sign(ax * P.vy - ay * P.vx) || (p.spin < 0 ? -1 : 1)
            const drag = Math.min(1, P.speed / 600)
            p.vx += (ax * 380 + P.vx * 0.3 - ay * side * 240 * drag) * n2 * dt
            p.vy += (ay * 380 + P.vy * 0.3 + ax * side * 240 * drag) * n2 * dt
            p.vr += side * n2 * (0.6 + drag) * dt
            p.thin = Math.max(p.thin, n2 * 0.9)
          }
        }
        for (const k of ks) {
          const d = Math.hypot(p.x - k.x, p.y - k.y)
          if (d > 320) continue
          const n = 1 - d / 320
          const [ax, ay] = away(k, p.x, p.y)
          const side = p.spin < 0 ? -1 : 1
          p.vx += (ax * 900 - ay * side * 300) * n * n
          p.vy += (ay * 900 + ax * side * 300) * n * n
          p.vr += side * n * 1.5
          p.thin = Math.max(p.thin, n * 0.7)
        }
        // The stir dies down, the puff drifts back to its place, the fog closes and thickens again.
        p.vx *= Math.pow(0.2, dt)
        p.vy *= Math.pow(0.2, dt)
        p.vr *= Math.pow(0.25, dt)
        p.ox += p.vx * dt - p.ox * Math.min(1, dt * 0.3)
        p.oy += p.vy * dt - p.oy * Math.min(1, dt * 0.3)
        p.x = p.hx + p.ox
        p.y = p.hy + p.oy
        p.rot += (p.spin + p.vr) * dt
        p.thin -= p.thin * Math.min(1, dt * 0.5)
      }
      if (active && motes.length < want / 3) motes.push({x: rand(0, fx.W), y: rand(fx.carTop + 80, fx.rowTop - 20), vx: rand(-4, 4), vy: rand(-3, 3), life: rand(6, 10), max: 10})
      for (const mo of motes) {
        const n = active ? near(P, mo.x, mo.y, 150) : 0
        if (n) { const [ax, ay] = away(P, mo.x, mo.y); mo.x += ax * n * 120 * dt; mo.y += ay * n * 120 * dt }
        mo.x += mo.vx * dt; mo.y += mo.vy * dt; mo.life -= dt
      }
      motes = motes.filter((mo) => mo.life > 0)
    },
    draw(g, alpha) {
      for (const p of puffs) {
        const fade = Math.max(0, Math.min(1, p.age / 3.5, p.out ? p.out / 3 : 1))
        if (fade <= 0) continue
        // Thinned fog spreads as it thins: a little larger, much fainter.
        const sz = p.size * (1 + p.thin * 0.3)
        g.globalAlpha = alpha * p.a * fade * fade * (1 - p.thin)
        g.save()
        g.translate(p.x, p.y)
        g.rotate(p.rot)
        g.drawImage(p.img, -sz / 2, -sz / 2, sz, sz)
        g.restore()
      }
      g.fillStyle = "rgba(230,225,245,0.8)"
      for (const mo of motes) {
        g.globalAlpha = alpha * Math.sin(Math.PI * (mo.life / mo.max)) * 0.6
        g.fillRect(mo.x, mo.y, 1.4, 1.4)
      }
    },
  }
}

// Go on an adventure: wind. Dust and a few cherry-blossom petals carried across in gusts, and
// streaks of wind sweeping through. Something stands where the pointer is, and the wind goes round it as round a
// post: what it carries slows as it nears, bends out along a smooth lens-shaped path to either
// side, and streams on and closes again behind. The post comes and goes gently (its strength
// eases in and out over a moment) and glides after the pointer, so nothing ever snaps.
function wind(fx) {
  // Petals: pinks from near-white to blush, each a little deeper at its base.
  const PETALS = [["#ffe6ee", "#ffc3d8"], ["#ffd6e4", "#ffb0cc"], ["#fff0f5", "#ffcce0"], ["#ffc9dc", "#f79fc0"], ["#ffdce8", "#ffb8d2"]]
  let t = 0, dust = [], leaves = [], gusts = [], next = 0.4
  const post = {x: 0, y: 0, k: 0}
  const R = 64
  // How far from the post's centre line the wind runs at `dx` along it: a lens 1.7 posts long and a
  // post tall, so the bend starts well before the post and closes well after.
  const lens = (dx) => { const u = dx / (R * 1.7); return u * u >= 1 ? 0 : R * Math.sqrt(1 - u * u) }
  // Where a point in the flow is carried to, sideways, by the post (0 when clear of it).
  const bend = (x, y, side) => {
    if (post.k < 0.01) return 0
    const dx = x - post.x, dy = y - post.y, edge = lens(dx) + 10
    if (edge <= 10 || Math.abs(dy) >= edge) return 0
    const sg = Math.abs(dy) > 3 ? Math.sign(dy) : side
    return sg * (edge - Math.abs(dy)) * post.k * (1 + 0.06 * Math.sin(t * 6 + dx * 0.05))
  }
  // A streak of wind meeting the post goes round it on one side, whole: the side is the one its
  // line lies on (or its own, head on), and every point of it within the lens is drawn onto that
  // side's arc — the pull coming in from nothing at the lens's tips, and weaker for a streak that
  // passes further from the post — so it bends out, round, and back without a kink anywhere.
  // Gently: a streak is air, not a leaf. Each streak carries a sideways offset of its own, with
  // momentum: the pointer pushes it away — on whichever side of the pointer the streak is at the
  // moment, so the pointer never passes through it but drives it ahead — and once the pointer is
  // gone a soft spring brings it back to its line. The push is a smooth bump along the streak's
  // length, centred where the push happened (`bx`, which follows the pointer only while it is
  // pushing), so moving the mouse off leaves the bump to settle where it is, never snapping.
  const PUSH = 900, D = 96
  const bump = (u) => (u * u >= 1 ? 0 : (1 - u * u) ** 2)
  const pushGust = (w, dt) => {
    let p = 0
    if (post.k > 0.01) {
      const left = w.x - w.l, right = w.x
      const along = post.x < left ? 1 - Math.min(1, (left - post.x) / 70) : post.x > right ? 1 - Math.min(1, (post.x - right) / 70) : 1
      const gap = w.y + w.off - post.y
      const ny = Math.max(0, 1 - Math.abs(gap) / D)
      p = post.k * along * ny
      if (p > 0) {
        const sg = Math.sign(gap) || w.side
        w.voff += sg * PUSH * p * dt
        w.bx += (post.x - w.bx) * Math.min(1, dt * 10)
      }
    }
    // The spring home, softly damped: back in about a second, with no snap.
    w.voff += (-w.off * 9 - w.voff * 5) * dt
    w.off += w.voff * dt
    if (p <= 0 && Math.abs(w.off) < 0.2 && Math.abs(w.voff) < 1) { w.off = 0; w.voff = 0 }
  }
  const bendGust = (w, x, y0) => (w.off === 0 ? y0 : y0 + w.off * bump((x - w.bx) / (R * 2.5)))
  // How much slower the wind is here: still in the lee and at the face of the post, full elsewhere.
  const slow = (x, y) => { if (post.k < 0.01) return 1; const d = Math.hypot(x - post.x, y - post.y); return 1 - 0.8 * post.k * Math.max(0, 1 - d / (R * 1.3)) }
  return {
    busy: () => false,
    stats: () => ({post: Math.round(post.k * 100) / 100, dust: dust.length, leaves: leaves.length, gusts: gusts.map((w) => ({x: Math.round(w.x), y: Math.round(w.y), l: Math.round(w.l), off: Math.round(w.off * 10) / 10}))}),
    step(dt, amount, active) {
      t += dt
      const P = fx.pointer
      const on = active && P.on
      // The post eases in where the pointer is and out when it goes, and glides after it.
      if (on) { post.x += (P.x - post.x) * Math.min(1, dt * 14); post.y += (P.y - post.y) * Math.min(1, dt * 14) }
      post.k += ((on ? 1 : 0) - post.k) * Math.min(1, dt * (on ? 5 : 3))
      const blow = 22 + 75 * Math.max(0, Math.sin(t * 0.3)) ** 2
      const wantDust = Math.round((fx.phone ? 40 : 110) * Math.min(1, amount / 1.5))
      const wantLeaves = Math.round((fx.phone ? 7 : 16) * Math.min(1, amount / 1.5))
      if (active) {
        while (dust.length < wantDust) dust.push({x: rand(0, fx.W), y: rand(fx.carTop + 60, fx.rowBottom - 20), k: rand(0.5, 1.2), ph: rand(0, 6), r: rand(1.2, 2.6), side: Math.random() < 0.5 ? -1 : 1, sway: 0})
        while (leaves.length < wantLeaves) leaves.push({x: rand(-fx.W * 0.5, 0), y: rand(fx.carTop + 80, fx.rowTop - 40), k: rand(0.7, 1.3), rot: rand(0, 6), vr: rand(1.5, 4), ph: rand(0, 6), c: pick(PETALS), s: rand(6, 11), side: Math.random() < 0.5 ? -1 : 1, sway: 0, tw: rand(0, 6), tws: rand(1.6, 3.2)})
        if ((next -= dt) <= 0) { next = rand(1.2, 2.6); gusts.push({x: -200, y: rand(fx.carTop + 90, fx.rowTop - 30), A: rand(6, 18), l: rand(160, 280), ph: rand(0, 6), v: rand(320, 520), side: Math.random() < 0.5 ? -1 : 1, off: 0, voff: 0, bx: 0}) }
      }
      // What the wind carries is eased sideways towards the path round the post (`sway`, the
      // sideways drift it has picked up, which dies away once it is past), and slowed at its face.
      const carry = (p, speed) => {
        const want = bend(p.x, p.y, p.side)
        p.sway += (want * 3 - p.sway) * Math.min(1, dt * 4)
        p.y += p.sway * dt
        p.x += speed * slow(p.x, p.y) * dt
      }
      for (const d of dust) {
        carry(d, blow * d.k)
        d.y += Math.sin(t * 1 + d.ph) * 5 * dt
        if (d.x > fx.W + 10) d.x = -10
      }
      dust = dust.slice(0, wantDust)
      for (const l of leaves) {
        carry(l, blow * l.k * 1.2)
        l.y += (Math.sin(t * 0.8 + l.ph) * 22 + 6) * dt
        l.rot += l.vr * dt * (blow / 160) * (1 + Math.abs(l.sway) / 60)
        if (l.x > fx.W + 30 || l.y > fx.rowBottom) { l.x = rand(-200, -30); l.y = rand(fx.carTop + 80, fx.rowTop - 40); l.sway = 0 }
      }
      leaves = leaves.slice(0, wantLeaves)
      for (const w of gusts) { w.x += w.v * dt; pushGust(w, dt) }
      gusts = gusts.filter((w) => w.x - w.l < fx.W + 50)
    },
    draw(g, alpha) {
      g.fillStyle = "rgba(245,235,215,0.85)"
      g.globalAlpha = alpha * 0.75
      for (const d of dust) g.fillRect(d.x, d.y, d.r, d.r)
      g.lineCap = "round"
      g.lineJoin = "round"
      g.strokeStyle = "rgba(255,255,255,1)"
      g.lineWidth = 1.6
      for (const w of gusts) {
        g.beginPath()
        // The streak, point by point, each carried round the post by the path the wind takes there.
        for (let i = 0; i <= 28; i++) {
          const x = w.x - w.l + (w.l * i) / 28
          const y0 = w.y + Math.sin(x / 70 + w.ph) * w.A
          const y = bendGust(w, x, y0)
          i ? g.lineTo(x, y) : g.moveTo(x, y)
        }
        g.globalAlpha = alpha * 0.35
        g.stroke()
      }
      // A petal: the cherry blossom's, rounded, with the small notch at its tip, turning over as
      // it tumbles (its width narrowing as it turns edge-on), a lighter heart, a faint vein.
      for (const l of leaves) {
        const s = l.s
        g.save()
        g.globalAlpha = alpha * 0.92
        g.translate(l.x, l.y)
        g.rotate(l.rot)
        g.scale(Math.abs(Math.cos(l.rot * 0.7 + l.tw)) * 0.75 + 0.25, 1)
        g.beginPath()
        g.moveTo(0, s * 0.95)
        g.bezierCurveTo(-s * 1.15, s * 0.35, -s * 0.95, -s * 0.9, -s * 0.28, -s * 0.95)
        g.quadraticCurveTo(0, -s * 0.6, s * 0.28, -s * 0.95)
        g.bezierCurveTo(s * 0.95, -s * 0.9, s * 1.15, s * 0.35, 0, s * 0.95)
        g.closePath()
        const grad = g.createRadialGradient(0, -s * 0.2, s * 0.1, 0, s * 0.3, s * 1.3)
        grad.addColorStop(0, l.c[0])
        grad.addColorStop(1, l.c[1])
        g.fillStyle = grad
        g.fill()
        g.strokeStyle = "rgba(255,255,255,0.35)"
        g.lineWidth = 0.6
        g.stroke()
        g.strokeStyle = "rgba(220,110,150,0.35)"
        g.lineWidth = 0.7
        g.beginPath(); g.moveTo(0, s * 0.85); g.quadraticCurveTo(s * 0.08, 0, 0, -s * 0.55); g.stroke()
        g.restore()
      }
    },
  }
}

// Feel like a kid: soap bubbles floating up from the first row, wobbling, and popping.
function bubbles(fx) {
  let list = [], pops = [], drips = [], acc = 0
  const pop = (b) => {
    b.gone = true
    pops.push({x: b.x, y: b.y, r: b.r, life: 0.35})
    for (let i = 0; i < 7; i++) { const a = rand(0, Math.PI * 2), v = rand(40, 140); drips.push({x: b.x + Math.cos(a) * b.r * 0.8, y: b.y + Math.sin(a) * b.r * 0.8, vx: Math.cos(a) * v, vy: Math.sin(a) * v - 40, life: rand(0.3, 0.6)}) }
  }
  return {
    busy: () => list.length + pops.length + drips.length > 0,
    step(dt, amount, active) {
      const cap = (fx.phone ? 8 : 20) * Math.min(1, amount / 1.5)
      // A bubble the pointer touches pops — a ring, and a few drops of soap flung out. A poke pops
      // the ones within reach of it.
      const P = fx.pointer, ks = pokes(fx, active)
      for (const b of list) {
        if (b.gone || b.age < 0.3) continue
        if ((active && P.on && Math.hypot(b.x - P.x, b.y - P.y) < b.r + 4) || ks.some((k) => Math.hypot(b.x - k.x, b.y - k.y) < b.r + 40)) pop(b)
      }
      for (const d of drips) { d.vy += 500 * dt; d.x += d.vx * dt; d.y += d.vy * dt; d.life -= dt }
      drips = drips.filter((d) => d.life > 0)
      if (active) {
        acc += 1.4 * (fx.W / 1000) * (amount / 1.5) * dt
        while (acc >= 1 && list.length < cap) { acc -= 1; list.push({x: rand(0, fx.W), y: rand(fx.carBottom - 120, fx.rowTop + 30), r: rand(10, 32), vy: -rand(7, 18), ph: rand(0, 6), life: rand(10, 18), age: 0}) }
      }
      for (const b of list) {
        b.y += b.vy * dt
        b.ph += dt * 1.1
        b.x += Math.sin(b.ph * 0.6) * 8 * dt
        b.life -= dt
        b.age += dt
        if (b.life <= 0 || b.y < fx.carTop + 70) { b.gone = true; pops.push({x: b.x, y: b.y, r: b.r, life: 0.35}) }
      }
      list = list.filter((b) => !b.gone)
      for (const p of pops) p.life -= dt
      pops = pops.filter((p) => p.life > 0)
    },
    draw(g, alpha) {
      for (const b of list) {
        g.globalAlpha = alpha * Math.min(1, b.life * 2, b.age / 1.2)
        const w = b.r * 2 * (1 + 0.05 * Math.sin(b.ph * 1.7)), h = b.r * 2 * (1 - 0.05 * Math.sin(b.ph * 1.7))
        g.drawImage(fx.sprites.bubble, b.x - w / 2, b.y - h / 2, w, h)
      }
      g.strokeStyle = "rgba(255,255,255,0.8)"
      g.lineWidth = 1.2
      for (const p of pops) {
        const k = 1 - p.life / 0.35
        g.globalAlpha = alpha * (1 - k)
        g.beginPath(); g.arc(p.x, p.y, p.r * (1 + 0.5 * k), 0, Math.PI * 2); g.stroke()
      }
      g.fillStyle = "rgba(255,255,255,0.85)"
      for (const d of drips) { g.globalAlpha = alpha * Math.min(1, d.life * 3); g.beginPath(); g.arc(d.x, d.y, 1.4, 0, Math.PI * 2); g.fill() }
    },
  }
}

// Travel back in time: the carousel as old film — warm tone, grain, a flicker, scratches and dust
// that come and go, darker at the corners.
function film(fx) {
  // The film's own pace: grain and flicker change about twelve times a second, not every frame.
  let scratches = [], hairs = [], flick = 0, flickTo = 0, tick = 0, ox = 0, oy = 0, grain = null, slip = 0
  return {
    busy: () => false,
    step(dt, _amount, active) {
      tick -= dt
      if (tick <= 0) {
        tick = 1 / 12
        flickTo = rand(0, 1)
        ox = Math.floor(rand(0, 128))
        oy = Math.floor(rand(0, 128))
        grain = pick(fx.sprites.grains)
      }
      flick += (flickTo - flick) * Math.min(1, dt * 6)
      // A pointer dragged fast across it scratches the print; a poke makes the frame slip.
      const P = fx.pointer
      if (active && P.on && P.speed > 320 && Math.random() < dt * 9) scratches.push({x: P.x + rand(-4, 4), life: rand(0.25, 0.55), max: 0.6, w: rand(0.8, 2), dark: Math.random() < 0.5})
      if (pokes(fx, active).length) { slip = 1; flick = 1 }
      slip *= Math.pow(0.004, dt)
      if (active && Math.random() < dt * 0.6) scratches.push({x: rand(0, fx.W), life: rand(0.8, 2), max: 2, w: rand(0.6, 1.6), dark: Math.random() < 0.4})
      for (const s of scratches) { s.life -= dt; s.x += rand(-0.6, 0.6) }
      scratches = scratches.filter((s) => s.life > 0)
      if (active && Math.random() < dt * 0.45) hairs.push({x: rand(0, fx.W), y: rand(fx.carTop + 60, fx.carBottom - 40), r: rand(6, 18), a0: rand(0, 6), life: rand(0.25, 0.6)})
      for (const h of hairs) h.life -= dt
      hairs = hairs.filter((h) => h.life > 0)
    },
    draw(g, alpha) {
      const top = fx.carTop, h = fx.carBottom - fx.carTop
      g.globalAlpha = alpha
      g.fillStyle = "rgba(112,70,24,0.16)"
      g.fillRect(0, top, fx.W, h)
      g.fillStyle = `rgba(255,235,190,${0.035 * flick})`
      g.fillRect(0, top, fx.W, h)
      if (slip > 0.02) {
        // The frame line sliding through: a dark bar down from the top, the picture below it a
        // touch brighter, as a print jumping in the gate.
        g.fillStyle = `rgba(10,6,2,${0.9 * slip})`
        g.fillRect(0, top, fx.W, 34 * slip)
        g.fillStyle = `rgba(255,240,210,${0.12 * slip})`
        g.fillRect(0, top + 34 * slip, fx.W, h)
      }
      const cx = fx.W / 2, cy = top + h / 2, R = Math.hypot(fx.W, h) / 2
      const v = g.createRadialGradient(cx, cy, R * 0.5, cx, cy, R)
      v.addColorStop(0, "rgba(20,10,0,0)")
      v.addColorStop(1, "rgba(20,10,0,0.45)")
      g.fillStyle = v
      g.fillRect(0, top, fx.W, h)
      // Grain, shifted every frame.
      g.save()
      g.beginPath(); g.rect(0, top, fx.W, h); g.clip()
      g.translate(-ox, -oy)
      g.fillStyle = g.createPattern(grain || fx.sprites.grains[0], "repeat")
      g.globalAlpha = alpha * 0.9
      g.fillRect(0, top, fx.W + 128, h + 128)
      g.restore()
      for (const s of scratches) {
        g.globalAlpha = alpha * Math.min(1, s.life * 2, (s.max - s.life) * 4) * 0.45
        g.fillStyle = s.dark ? "rgba(30,20,10,1)" : "rgba(255,250,235,1)"
        g.fillRect(s.x, top, s.w, h)
      }
      g.strokeStyle = "rgba(20,15,10,0.8)"
      g.lineWidth = 1
      g.globalAlpha = alpha
      for (const hr of hairs) { g.beginPath(); g.arc(hr.x, hr.y, hr.r, hr.a0, hr.a0 + 2.2); g.stroke() }
    },
  }
}

// Something true: a documentary camera's viewfinder over the carousel — corner marks, REC blinking,
// a running timecode, the exposure, and a focus box that hunts across the posters and locks.
function viewfinder(fx) {
  let t = 0, focus = null, shutter = 0
  return {
    busy: () => false,
    step(dt, _amount, active) {
      if (!active) return
      t += dt
      shutter *= Math.pow(0.0003, dt)
      if (pokes(fx, true).length) shutter = 1
      const h = fx.carBottom - fx.carTop
      const area = fx.W >= 1024
        ? {x0: fx.W * 0.6, x1: fx.W * 0.9, y0: fx.carTop + h * 0.22, y1: fx.carTop + h * 0.7}
        : {x0: fx.W * 0.25, x1: fx.W * 0.75, y0: fx.carTop + 110, y1: fx.carTop + 300}
      if (!focus) focus = {x: (area.x0 + area.x1) / 2, y: (area.y0 + area.y1) / 2, tx: 0, ty: 0, next: 0, lock: 0}
      // The pointer over the area is what the camera is on: the box hunts to it and holds; left
      // alone, it goes back to picking its own subjects.
      const P = fx.pointer
      if (P.on) { if (Math.hypot(P.x - focus.tx, P.y - focus.ty) > 6) focus.lock = 0; focus.tx = P.x; focus.ty = P.y; focus.next = 2 }
      else if ((focus.next -= dt) <= 0) { focus.tx = rand(area.x0, area.x1); focus.ty = rand(area.y0, area.y1); focus.next = rand(2.5, 4); focus.lock = 0 }
      const k = Math.min(1, dt * 3)
      focus.x += (focus.tx - focus.x) * k
      focus.y += (focus.ty - focus.y) * k
      if (Math.hypot(focus.tx - focus.x, focus.ty - focus.y) < 2) focus.lock += dt
    },
    draw(g, alpha) {
      if (!focus) return
      // The shutter: a soft, brief lift of the picture, gone in a blink — not a flashbang.
      if (shutter > 0.01) { g.globalAlpha = alpha * shutter * 0.28; g.fillStyle = "#fff"; g.fillRect(0, fx.carTop, fx.W, fx.carBottom - fx.carTop) }
      const gut = fx.W < 640 ? 16 : fx.W < 1024 ? 24 : fx.W < 1280 ? 48 : 64
      const L = gut, R = fx.W - gut, T = fx.carTop + 76, B = fx.carBottom - 64
      const c = 26
      g.globalAlpha = alpha * 0.75
      g.strokeStyle = "rgba(255,255,255,1)"
      g.lineWidth = 2
      g.beginPath()
      g.moveTo(L, T + c); g.lineTo(L, T); g.lineTo(L + c, T)
      g.moveTo(R - c, T); g.lineTo(R, T); g.lineTo(R, T + c)
      g.moveTo(L, B - c); g.lineTo(L, B); g.lineTo(L + c, B)
      g.moveTo(R - c, B); g.lineTo(R, B); g.lineTo(R, B - c)
      g.stroke()

      g.font = "600 12px ui-monospace, SFMono-Regular, Menlo, monospace"
      g.textBaseline = "middle"
      if (Math.floor(t * 1.2) % 2 === 0) {
        g.globalAlpha = alpha
        g.fillStyle = "#ff3b3b"
        g.beginPath(); g.arc(L + 18, T + 20, 5, 0, Math.PI * 2); g.fill()
      }
      g.globalAlpha = alpha * 0.85
      g.fillStyle = "#fff"
      g.textAlign = "left"
      g.fillText("REC", L + 30, T + 20)
      const f = Math.floor(t * 24)
      const tc = [Math.floor(f / 86400), Math.floor(f / 1440) % 60, Math.floor(f / 24) % 60, f % 24].map((n) => String(n).padStart(2, "0")).join(":")
      g.textAlign = "right"
      g.fillText(tc, R - 12, T + 20)
      if (fx.W >= 640) {
        g.globalAlpha = alpha * 0.6
        g.textAlign = "left"
        g.fillText("ISO 800   1/50   f2.8", L + 12, B - 18)
        g.textAlign = "right"
        g.fillText("4K · 24p", R - 12, B - 18)
      }

      const s = 34, locked = focus.lock > 0.25, q = 9
      g.globalAlpha = alpha * (locked ? 0.95 : 0.7)
      g.strokeStyle = locked ? "#4ade80" : "#fff"
      g.lineWidth = 1.5
      const x = focus.x, y = focus.y
      g.beginPath()
      g.moveTo(x - s, y - s + q); g.lineTo(x - s, y - s); g.lineTo(x - s + q, y - s)
      g.moveTo(x + s - q, y - s); g.lineTo(x + s, y - s); g.lineTo(x + s, y - s + q)
      g.moveTo(x - s, y + s - q); g.lineTo(x - s, y + s); g.lineTo(x - s + q, y + s)
      g.moveTo(x + s - q, y + s); g.lineTo(x + s, y + s); g.lineTo(x + s, y + s - q)
      g.stroke()
    },
  }
}

// How many seconds of an effect are run ahead, unseen, when its mood comes up, so it fades in
// already under way (confetti over the whole carousel, the fog rolled in) instead of starting
// from an empty sky. Run in steps of a tenth of a second, without drawing.
const WARM = {cry: 3, scared: 3, laugh: 16, love: 12, action: 3, mystery: 12, adventure: 8, kid: 10}

function warmed(fx, effect, slug) {
  const amount = fx.amount()
  for (let t = 0; t < (WARM[slug] || 0); t += 0.1) effect.step(0.1, amount, true)
  return effect
}

const EFFECTS = {
  cry: (fx) => rain(fx, RAIN.cry),
  scared: (fx) => rain(fx, RAIN.scared),
  laugh: confetti,
  love: bokeh,
  thrill: heartbeat,
  action: embers,
  escape: fireflies,
  mystery: fog,
  adventure: wind,
  kid: bubbles,
  past: film,
  true: viewfinder,
}

// ── how strong a device is ─────────────────────────────────────────────
// A short drawing test (stamping sprites, then reading a pixel back so the drawing is really done),
// with the browser's hints about cores and memory. 1 = everything, less = fewer particles, 0 = off.
function measure(spr) {
  const c = document.createElement("canvas")
  c.width = 640
  c.height = 400
  const g = c.getContext("2d")
  let best = Infinity
  for (let round = 0; round < 2; round++) {
    const t0 = performance.now()
    for (let i = 0; i < 1500; i++) g.drawImage(spr, (i * 37) % 600, (i * 53) % 360, 16, 16)
    g.getImageData(0, 0, 1, 1)
    best = Math.min(best, performance.now() - t0)
  }
  const cores = navigator.hardwareConcurrency || 4
  const memory = navigator.deviceMemory || 8
  let level = best < 8 ? 1 : best < 16 ? 0.7 : best < 32 ? 0.45 : 0
  if (cores <= 2 || memory <= 2) level = Math.min(level, 0.45)
  if (cores <= 2 && memory <= 1) level = 0
  return {ms: best, cores, memory, level}
}

const SAVED = "roki:fx"
const store = {
  get: () => { try { return localStorage.getItem(SAVED) } catch { return null } },
  set: (v) => { try { v ? localStorage.setItem(SAVED, v) : localStorage.removeItem(SAVED) } catch {} },
}

// ── the hook ───────────────────────────────────────────────────────────

export const MoodFx = {
  mounted() {
    this.canvas = this.el.querySelector("#mood-fx-canvas")
    this.canvas.style.transition = "opacity 0.4s ease"
    this.ctx = this.canvas.getContext("2d")
    this.picker = this.el.querySelector("[data-fx-stage]")
    this.fixed = this.el.dataset.mood || null
    this.share = Number(this.el.dataset.amount) || 1
    this.mode = "auto"
    this.density = 1.5
    this.phone = matchMedia("(hover: none)").matches || innerWidth < 640
    this.reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
    this.sprites = {
      water: dropSprite("water"), blood: dropSprite("blood"),
      rose: bokehSprite(255, 95, 150), blush: bokehSprite(255, 160, 200), warm: bokehSprite(255, 205, 150),
      white: glowSprite(255, 255, 255, 0), fire: glowSprite(255, 140, 40, 100), ember: glowSprite(255, 120, 30, 120),
      firefly: glowSprite(200, 255, 110, 60), bubble: bubbleSprite(),
      fogs: [fogSprite(), fogSprite(), fogSprite()], puffs: [puffSprite(), puffSprite(), puffSprite()], grains: [grainSprite(), grainSprite(), grainSprite()],
    }
    this.running = [] // {slug, fx, fade}
    // What the effects feel of the pointer: where it is over the area (in the canvas's own
    // coordinates), whether it is on it, how fast it moves; and the pokes — presses, taps.
    // `path`: every move since the last frame, so an effect can follow the hand's real curve
    // rather than a straight line between where it was at one frame and the next.
    this.pointer = {on: false, x: 0, y: 0, vx: 0, vy: 0, speed: 0, t: 0, path: []}
    this.pokes = []
    // Live, for the console and tuning: what each running effect holds this instant (`fxStats` is
    // a snapshot taken twice a second).
    this.el.fxNow = () => Object.fromEntries(this.running.map((r) => [r.slug, r.fx.stats ? r.fx.stats() : null]))
    this.onPointer = (e) => this.pointerEvent(e)
    for (const ev of ["pointermove", "pointerdown", "pointerup", "pointercancel", "pointerleave"]) this.el.addEventListener(ev, this.onPointer, {passive: true})
    this.ticks = []
    this.work = []
    this.slow = 0
    this.onScreen = true
    this.loop = this.loop.bind(this)

    this.device = measure(this.sprites.water)
    this.quality = this.device.level
    this.choice = store.get() // "on": turned on anyway on a slow device; "off": switched off here

    this.layout()
    this.ro = new ResizeObserver(() => this.layout())
    this.ro.observe(this.el)
    // Only while a good part of the carousel is on screen: scrolled down to the rows, it stops
    // (nothing falls into view from the top) and fades out, and starts again on the way back up.
    this.io = new IntersectionObserver(([e]) => {
      this.onScreen = e.intersectionRatio >= 0.35
      this.canvas.style.opacity = this.onScreen ? "1" : "0"
      this.wake()
    }, {threshold: [0, 0.2, 0.35, 0.5, 1]})
    this.io.observe(this.picker)
    this.onVis = () => this.wake()
    document.addEventListener("visibilitychange", this.onVis)
    this.timer = setInterval(() => { this.wake(); this.stats() }, 500)
    this.wake()
  },

  destroyed() {
    cancelAnimationFrame(this.raf)
    clearInterval(this.timer)
    this.ro.disconnect()
    this.io.disconnect()
    document.removeEventListener("visibilitychange", this.onVis)
    for (const ev of ["pointermove", "pointerdown", "pointerup", "pointercancel", "pointerleave"]) this.el.removeEventListener(ev, this.onPointer)
    if (this.note) this.note.remove()
  },

  // A mouse is on the area while it is over it; a finger while it is down. Its speed is from the
  // last two moves (and falls to nothing in the loop once the moves stop). A press is a poke,
  // `fresh` for the frame after it.
  pointerEvent(e) {
    const P = this.pointer, now = performance.now() / 1000
    const base = this.el.getBoundingClientRect()
    const x = e.clientX - base.left, y = e.clientY - base.top
    const touch = e.pointerType === "touch"
    if (e.type === "pointerleave" || e.type === "pointercancel" || (e.type === "pointerup" && touch)) { P.on = false; P.speed = 0; return }
    // Only over the animated area: on the home page the hook's box goes on down the rows, where
    // the pointer is on posters, not in the weather.
    if (y > this.H) { P.on = false; P.speed = 0; return }
    if (e.type === "pointerdown") {
      // A press on a control — a mood's tab, a button, a link — is for the control, not the weather.
      if (e.target.closest && e.target.closest("a, button, [role=tab]")) return
      this.pokes.push({x, y, age: 0, fresh: true})
      if (touch) { P.on = true; P.x = x; P.y = y; P.t = now; P.speed = 0 }
      return
    }
    if (e.type !== "pointermove" || (touch && !P.on)) return
    if (P.on) {
      const dtp = Math.max(0.004, now - P.t)
      P.vx += ((x - P.x) / dtp - P.vx) * 0.5
      P.vy += ((y - P.y) / dtp - P.vy) * 0.5
      P.speed = Math.hypot(P.vx, P.vy)
    }
    P.on = true; P.x = x; P.y = y; P.t = now
    if (P.path.length < 64) P.path.push({x, y})
    this.wake()
  },

  layout() {
    const base = this.el.getBoundingClientRect()
    const pick = this.picker.getBoundingClientRect()
    const row = this.el.querySelector("#row-movies")
    const rr = row ? row.getBoundingClientRect() : pick
    this.W = Math.round(base.width)
    this.carTop = pick.top - base.top
    this.carBottom = pick.bottom - base.top
    // Where the area's words begin (a mood page keeps its open space above them).
    const words = this.picker.querySelector("p, h1")
    this.textTop = words ? words.getBoundingClientRect().top - base.top : this.carTop + 160
    // Nothing goes past halfway between the carousel and the first row: the posters are left
    // alone. `rowTop`/`rowBottom` (where the effects end) are that line.
    const floor = Math.round((this.carBottom + Math.max(this.carBottom, rr.top - base.top)) / 2)
    this.rowTop = floor
    this.rowBottom = floor
    this.H = floor
    const dpr = Math.min(window.devicePixelRatio || 1, this.phone ? 1 : 1.5)
    if (this.canvas.width !== Math.round(this.W * dpr) || this.canvas.height !== Math.round(this.H * dpr)) {
      this.canvas.width = Math.round(this.W * dpr)
      this.canvas.height = Math.round(this.H * dpr)
      this.canvas.style.width = `${this.W}px`
      this.canvas.style.height = `${this.H}px`
    }
    this.dpr = dpr
  },

  // How much of everything: the density chosen, what the device can take, less on a phone.
  amount() { return this.density * this.share * Math.max(this.quality, this.choice === "on" ? 0.45 : 0) * (this.phone ? 0.6 : 1) },

  // Off for reduced motion and for a device switched off (`localStorage["roki:fx"] = "off"`); on a
  // slow device only when its person turned it on anyway.
  enabled() { return !this.reduced && this.choice !== "off" && (this.quality > 0 || this.choice === "on") },

  target() {
    if (this.mode === "off") return null
    if (this.mode !== "auto") return EFFECTS[this.mode] ? this.mode : null
    if (this.fixed) return EFFECTS[this.fixed] ? this.fixed : null
    const chip = this.picker.querySelector('[data-mood-chip][aria-selected="true"]')
    const slug = chip && chip.dataset.moodChip
    return EFFECTS[slug] ? slug : null
  },

  wake() {
    if (this.raf || !this.onScreen || document.hidden) return
    const want = this.target()
    if (want && !this.enabled()) { this.tellOff(); return }
    if (!want && !this.running.length) return
    this.lastDraw = performance.now()
    // A fresh start: the frames before it (or a pause) say nothing about this device.
    this.startedAt = this.lastDraw
    this.ticks = []
    this.work = []
    this.raf = requestAnimationFrame(this.loop)
  },

  loop(now) {
    this.raf = null
    if (!this.onScreen || document.hidden) return
    // 30 frames a second is plenty for weather; the frames between are skipped.
    if (now - this.lastDraw < 1000 / FPS - 4) { this.raf = requestAnimationFrame(this.loop); return }
    const dt = Math.min(0.1, (now - this.lastDraw) / 1000)
    this.lastDraw = now
    this.ticks.push(now)
    const t0 = performance.now()

    const want = this.enabled() ? this.target() : null
    if (want && !this.running.some((r) => r.slug === want)) this.running.push({slug: want, fx: warmed(this, EFFECTS[want](this), want), fade: 0})
    const amount = this.amount()
    // A pointer that has stopped moving has no speed, whatever its last move was.
    if (now / 1000 - this.pointer.t > 0.07) { this.pointer.vx = this.pointer.vy = 0; this.pointer.speed = 0 }
    for (const r of this.running) {
      const active = r.slug === want
      r.fade += ((active ? 1 : 0) - r.fade) * Math.min(1, dt * 3)
      r.fx.step(dt, amount, active)
    }
    for (const k of this.pokes) { k.fresh = false; k.age += dt }
    this.pokes = this.pokes.filter((k) => k.age < 2)
    this.pointer.path.length = 0
    // The mood that went fades out; once faded it is dropped, whatever it still held.
    this.running = this.running.filter((r) => r.slug === want || r.fade > 0.02)

    // Scrolled down past the top, it thins with the scroll: gone once two thirds of the area
    // are above the window (where it also stops).
    const above = Math.max(0, -this.picker.getBoundingClientRect().top)
    const thin = Math.max(0, 1 - above / Math.max(1, (this.carBottom - this.carTop) * 0.65))

    const g = this.ctx
    g.setTransform(this.dpr, 0, 0, this.dpr, 0, 0)
    g.clearRect(0, 0, this.W, this.H)
    for (const r of this.running) { g.save(); r.fx.draw(g, r.fade * thin); g.restore() }
    // The lower edge fades, so what reaches the line thins out instead of being cut. Drawn here
    // rather than as a CSS mask, which made the page costlier to put together while the
    // carousel's slides change underneath.
    g.globalAlpha = 1
    g.globalCompositeOperation = "destination-out"
    if (!this.edge || this.edgeH !== this.H) {
      this.edge = g.createLinearGradient(0, this.H - 56, 0, this.H)
      this.edge.addColorStop(0, "rgba(0,0,0,0)")
      this.edge.addColorStop(1, "rgba(0,0,0,1)")
      this.edgeH = this.H
    }
    g.fillStyle = this.edge
    g.fillRect(0, this.H - 56, this.W, 56)
    g.globalCompositeOperation = "source-over"
    this.work.push(performance.now() - t0)

    if (this.running.length) this.raf = requestAnimationFrame(this.loop)
    else g.clearRect(0, 0, this.W, this.H)
  },

  // Twice a second: the device's real frames. Slow frames step the amount
  // down; still too slow at the lowest, it stops and says so.
  stats() {
    const now = performance.now()
    this.ticks = this.ticks.filter((t) => now - t <= 1000)
    const work = this.work.splice(0)
    const avg = work.length ? work.reduce((a, b) => a + b, 0) / work.length : 0
    const fps = this.ticks.length
    // Judged only on a full second of running: just after a start or a pause, too few frames have
    // been drawn to say the device is slow.
    if (this.raf && fps > 0 && this.choice !== "on" && now - this.startedAt > 1500) {
      if (fps < 24 || avg > 12) {
        this.quality = Math.max(0.3, this.quality * 0.8)
        if (this.quality <= 0.3 && ++this.slow >= 6) { this.quality = 0; this.tellOff() }
      } else {
        this.slow = 0
        if (fps >= 29 && avg < 5) this.quality = Math.min(this.device.level || 0.3, this.quality * 1.08)
      }
    }
    // For the console: what it is doing and why.
    this.el.fxStats = {fps: this.raf ? fps : 0, ms: avg, effect: this.running.map((r) => r.slug), onScreen: this.onScreen, device: this.device, quality: this.quality, choice: this.choice, pointer: this.pointer, effects: Object.fromEntries(this.running.map((r) => [r.slug, r.fx.stats ? r.fx.stats() : null]))}
  },

  // The note in the corner: once a session, when an animation would have played.
  tellOff() {
    let seen = false
    try { seen = sessionStorage.getItem("roki:fx-note") === "1" } catch {}
    if (this.note || seen || this.reduced) return
    try { sessionStorage.setItem("roki:fx-note", "1") } catch {}
    const n = document.createElement("div")
    n.className = "fixed bottom-4 right-4 z-50 flex max-w-xs items-start gap-3 rounded-2xl bg-neutral-900/90 p-3 text-xs text-white shadow-2xl ring-1 ring-white/15 backdrop-blur transition-opacity duration-500"
    n.innerHTML = `<div class="flex-1"><p class="font-semibold">Animations off</p><p class="mt-0.5 text-white/70">This device seems a little slow for the mood animations, so they are off to keep the site smooth.</p><button type="button" data-on class="mt-2 font-semibold text-primary hover:underline">Turn them on anyway</button></div><button type="button" data-x class="text-white/60 hover:text-white" aria-label="Close">✕</button>`
    const close = () => { n.style.opacity = "0"; setTimeout(() => n.remove(), 500); this.note = null }
    n.querySelector("[data-x]").addEventListener("click", close)
    n.querySelector("[data-on]").addEventListener("click", () => { this.choice = "on"; store.set("on"); this.quality = Math.max(this.quality, 0.45); close(); this.wake() })
    setTimeout(close, 12000)
    document.body.appendChild(n)
    this.note = n
  },
}
