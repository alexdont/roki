// The mood lab (priv/static/lab/moods.html): trial versions of the "Have a good cry" and "Be
// scared" weather, run in the real MoodFx hook beside the current ones. Each is an effect in the
// hook's own shape — `step(dt, amount, active)`, `draw(g, alpha)` — reading what every effect reads
// of the hook (`fx.W`, `fx.H`, `fx.carTop`, `fx.carBottom`, `fx.phone`, `fx.pointer`, `fx.pokes`,
// `fx.sprites`), so the one chosen moves into mood_fx.js as it is.
//
// Built on its own (esbuild → priv/static/lab/mood-lab.js), never part of app.js.
import {MoodFx, EFFECTS} from "../mood_fx"

const rand = (a, b) => a + Math.random() * (b - a)
const near = (P, x, y, R) => { if (!P.on) return 0; const d = Math.hypot(x - P.x, y - P.y); return d < R ? 1 - d / R : 0 }
const fresh = (fx, active) => (active ? fx.pokes.filter((k) => k.fresh) : [])
// Every point the pointer passed since the last frame (its real curve), else where it is.
const path = (P) => (P.path && P.path.length ? P.path : P.on ? [{x: P.x, y: P.y}] : [])

// An offscreen layer at a fraction of the size, drawn scaled up (soft for free, cheap to fill).
function layer(fx, k) {
  const c = document.createElement("canvas")
  const fit = () => {
    const w = Math.max(1, Math.round(fx.W / k)), h = Math.max(1, Math.round(fx.H / k))
    if (c.width !== w || c.height !== h) { c.width = w; c.height = h; return true }
    return false
  }
  fit()
  return {c, g: c.getContext("2d"), fit, k}
}

// ══ Have a good cry ══════════════════════════════════════════════════════════════════════════

// B · Misted window. The glass is fogged with a cold breath; a few heavy drops run down it slowly
// and leave clear tracks, which mist over again; the hand wipes a clear stroke that fogs back in a
// few seconds. Quiet, few things moving.
function mist(fx) {
  const L = layer(fx, 2)
  const drops = []
  let acc = 0, filled = false
  const MIST = "rgb(196,208,224)"
  const clear = (x, y, r) => {
    const g = L.g, k = L.k
    const gr = g.createRadialGradient(x / k, y / k, 0, x / k, y / k, r / k)
    gr.addColorStop(0, "rgba(0,0,0,0.75)"); gr.addColorStop(0.6, "rgba(0,0,0,0.35)"); gr.addColorStop(1, "rgba(0,0,0,0)")
    g.globalCompositeOperation = "destination-out"; g.fillStyle = gr
    g.beginPath(); g.arc(x / k, y / k, r / k, 0, Math.PI * 2); g.fill()
    g.globalCompositeOperation = "source-over"
  }
  return {
    busy: () => true,
    step(dt, amount, active) {
      if (L.fit() || !filled) { L.g.fillStyle = MIST; L.g.fillRect(0, 0, L.c.width, L.c.height); filled = true }
      // The breath settles back over whatever was wiped.
      L.g.globalAlpha = Math.min(1, dt * 0.35); L.g.fillStyle = MIST; L.g.fillRect(0, 0, L.c.width, L.c.height); L.g.globalAlpha = 1
      if (active) {
        acc += dt * 0.55 * amount
        while (acc >= 1) { acc -= 1; drops.push({x: rand(0, fx.W), y: rand(fx.carTop - 20, fx.carTop + (fx.carBottom - fx.carTop) * 0.45), r: rand(4, 7.5), v: 0, wait: rand(0.5, 2.5), wob: rand(0, 6)}) }
        for (const p of path(fx.pointer)) clear(p.x, p.y, fx.phone ? 38 : 54)
      }
      for (const d of drops) {
        d.wait -= dt
        if (d.wait > 0) { d.v = 0; continue }
        // Runs in fits: speeds up, catches, stops, goes again.
        d.v = Math.min(d.v + dt * 60, 46 + d.r * 4)
        if (Math.random() < dt * 0.6) { d.wait = rand(0.3, 1.4); d.v = 0 }
        d.wob += dt * 2; d.x += Math.sin(d.wob) * dt * 6
        d.y += d.v * dt
        clear(d.x, d.y - d.r * 0.6, d.r * 1.05)
      }
      for (let i = drops.length - 1; i >= 0; i--) if (drops[i].y > fx.H + 20) drops.splice(i, 1)
    },
    draw(g, alpha) {
      g.globalAlpha = 0.3 * alpha
      g.imageSmoothingEnabled = true; g.imageSmoothingQuality = "high"
      g.drawImage(L.c, 0, 0, fx.W, fx.H)
      g.globalAlpha = alpha
      for (const d of drops) g.drawImage(fx.sprites.water, d.x - d.r * 1.3, d.y - d.r * 1.3, d.r * 2.6, d.r * 2.6)
    },
  }
}

// C · Drizzle beyond the window. Fine slanted rain far off, in three depths (the near one faster
// and fainter), and now and then the slow sweep of a passing car's lights across the room. The
// pointer is an umbrella: no rain falls under it.
function drizzle(fx) {
  const lines = [], DEPTHS = [[0.35, 0.18, 380], [0.6, 0.12, 620], [1, 0.08, 980]]
  let acc = 0, sweep = null, nextSweep = rand(4, 8)
  return {
    busy: () => true,
    step(dt, amount, active) {
      if (active) {
        acc += dt * fx.W / 1000 * 220 * amount
        while (acc >= 1) {
          acc -= 1
          const [s, a, v] = DEPTHS[Math.floor(Math.random() * 3)]
          lines.push({x: rand(-60, fx.W), y: rand(-60, -10), s, a, v: v * rand(0.85, 1.15), len: 10 + 22 * s})
        }
        nextSweep -= dt
        if (nextSweep < 0 && !sweep) { sweep = {t: 0, dur: rand(3.5, 5), dir: Math.random() < 0.5 ? 1 : -1}; nextSweep = rand(7, 14) }
      }
      for (const l of lines) { l.y += l.v * dt; l.x += l.v * 0.18 * dt }
      for (let i = lines.length - 1; i >= 0; i--) if (lines[i].y > fx.H + 30) lines.splice(i, 1)
      if (sweep) { sweep.t += dt; if (sweep.t > sweep.dur) sweep = null }
    },
    draw(g, alpha) {
      const P = fx.pointer
      g.lineCap = "round"
      for (const l of lines) {
        const shelter = near(P, l.x, l.y, fx.phone ? 70 : 110)
        if (shelter > 0.15) continue
        g.globalAlpha = l.a * alpha * 2.2
        g.strokeStyle = "rgb(200,214,235)"; g.lineWidth = 0.6 + l.s * 0.7
        g.beginPath(); g.moveTo(l.x, l.y); g.lineTo(l.x - l.len * 0.18, l.y - l.len); g.stroke()
      }
      if (sweep) {
        const p = sweep.t / sweep.dur, x = sweep.dir > 0 ? -0.3 * fx.W + p * 1.6 * fx.W : 1.3 * fx.W - p * 1.6 * fx.W
        const a = Math.sin(Math.PI * p) * 0.16 * alpha
        const gr = g.createLinearGradient(x - fx.W * 0.25, 0, x + fx.W * 0.25, 0)
        gr.addColorStop(0, "rgba(255,236,200,0)"); gr.addColorStop(0.5, `rgba(255,236,200,${a})`); gr.addColorStop(1, "rgba(255,236,200,0)")
        g.globalAlpha = 1; g.fillStyle = gr; g.fillRect(0, 0, fx.W, fx.H)
      }
      // A cold cast over everything, a little.
      g.globalAlpha = 0.12 * alpha; g.fillStyle = "rgb(40,60,95)"; g.fillRect(0, 0, fx.W, fx.H)
    },
  }
}

// D · Ripples. Drops land on dark water along the foot of the slide: rings open out (flattened,
// seen from above at a slant) and fade; the pointer, passing low, draws its own rings, a press a
// big one. The upper part stays clear for the words and the posters.
function ripples(fx) {
  const rings = [], falls = []
  let acc = 0, lastTrail = 0
  const top = () => fx.carTop + (fx.carBottom - fx.carTop) * 0.6
  const ring = (x, y, big = 1) => rings.push({x, y, r: 1, v: rand(26, 36) * big, life: rand(1.8, 2.6) * big, age: 0, w: big > 1 ? 1.6 : 1})
  return {
    busy: () => true,
    step(dt, amount, active) {
      if (active) {
        acc += dt * 5 * amount * fx.W / 1200
        while (acc >= 1) { acc -= 1; const y = rand(top(), fx.H - 8); falls.push({x: rand(0, fx.W), y: y - rand(140, 260), to: y, v: 900}) }
        lastTrail -= dt
        for (const p of path(fx.pointer)) if (p.y > top() && lastTrail < 0) { ring(p.x, p.y, 0.8); lastTrail = 0.12 }
        for (const k of fresh(fx, active)) if (k.y > top() - 40) { ring(k.x, Math.max(k.y, top()), 2); ring(k.x, Math.max(k.y, top()), 1.4) }
      }
      for (const f of falls) f.y += f.v * dt
      for (let i = falls.length - 1; i >= 0; i--) if (falls[i].y >= falls[i].to) { ring(falls[i].x, falls[i].to); falls.splice(i, 1) }
      for (const r of rings) { r.age += dt; r.r += r.v * dt * (1 - r.age / r.life * 0.6) }
      for (let i = rings.length - 1; i >= 0; i--) if (rings[i].age > rings[i].life) rings.splice(i, 1)
    },
    draw(g, alpha) {
      // The water: a dark, faintly lit band, so the rings have something to sit on.
      const t = top(), gr = g.createLinearGradient(0, t - 40, 0, fx.H)
      gr.addColorStop(0, "rgba(10,18,32,0)"); gr.addColorStop(0.35, `rgba(10,18,32,${0.45 * alpha})`); gr.addColorStop(1, `rgba(6,10,20,${0.7 * alpha})`)
      g.fillStyle = gr; g.fillRect(0, t - 40, fx.W, fx.H - t + 40)
      g.strokeStyle = "rgb(190,210,240)"
      for (const r of rings) {
        const a = (1 - r.age / r.life) ** 1.5 * alpha
        // Flatter the further up (further off) the water.
        const flat = 0.18 + 0.14 * (r.y - t) / Math.max(1, fx.H - t)
        for (const [k, w] of [[1, 0.55], [0.72, 0.3]]) {
          g.globalAlpha = a * w; g.lineWidth = r.w
          g.beginPath(); g.ellipse(r.x, r.y, r.r * k, r.r * k * flat, 0, 0, Math.PI * 2); g.stroke()
        }
      }
      g.globalAlpha = 0.5 * alpha; g.strokeStyle = "rgb(210,225,250)"; g.lineWidth = 1
      for (const f of falls) { g.beginPath(); g.moveTo(f.x, f.y); g.lineTo(f.x, f.y - 16); g.stroke() }
    },
  }
}

// ══ Be scared ═══════════════════════════════════════════════════════════════════════════════

// B · Flashlight. The room is dark; a torch shows a round of it. With the pointer over the slide
// the torch is in your hand; without, it searches the room by itself, slowly. Now and then it
// stutters and goes out for a moment. A press clicks it off and on.
function flashlight(fx) {
  let x = 0, y = 0, t = 0, out = 0, stutter = 0, nextStutter = rand(5, 9), began = false
  return {
    busy: () => true,
    step(dt, amount, active) {
      t += dt
      if (!began) { x = fx.W * 0.6; y = (fx.carTop + fx.carBottom) / 2; began = true }
      const P = fx.pointer
      const tx = P.on ? P.x : fx.W * (0.5 + 0.32 * Math.sin(t * 0.23) + 0.1 * Math.sin(t * 0.61))
      const ty = P.on ? P.y : (fx.carTop + fx.carBottom) / 2 + (fx.carBottom - fx.carTop) * (0.18 * Math.sin(t * 0.37) + 0.06 * Math.sin(t * 1.3))
      // A hand's lag: it follows, it does not snap.
      x += (tx - x) * Math.min(1, dt * (P.on ? 9 : 2)); y += (ty - y) * Math.min(1, dt * (P.on ? 9 : 2))
      if (active) {
        nextStutter -= dt
        if (nextStutter < 0) { stutter = rand(0.5, 1.1); nextStutter = rand(7, 13) }
        for (const _ of fresh(fx, active)) out = 0.35
      }
      stutter = Math.max(0, stutter - dt); out = Math.max(0, out - dt)
    },
    draw(g, alpha) {
      // The torch's strength this frame: steady, but for a stutter (fast irregular flicker) or a click.
      let on = 1
      if (stutter > 0) on = Math.random() < 0.45 ? rand(0, 0.35) : rand(0.6, 1)
      if (out > 0) on = 0
      const R = (fx.phone ? 150 : 230)
      g.globalAlpha = alpha
      g.fillStyle = "rgba(3,2,4,0.8)"; g.fillRect(0, 0, fx.W, fx.H)
      if (on > 0) {
        g.globalCompositeOperation = "destination-out"
        const gr = g.createRadialGradient(x, y, R * 0.12, x, y, R)
        gr.addColorStop(0, `rgba(0,0,0,${0.97 * on})`); gr.addColorStop(0.55, `rgba(0,0,0,${0.85 * on})`); gr.addColorStop(1, "rgba(0,0,0,0)")
        g.fillStyle = gr; g.beginPath(); g.arc(x, y, R, 0, Math.PI * 2); g.fill()
        g.globalCompositeOperation = "source-over"
        // The torch's warm colour on what it shows.
        // The beam itself: warm light laid over what it shows, brightest at its heart, a faint
        // ring at its edge as a real torch has.
        g.globalCompositeOperation = "lighter"
        const warm = g.createRadialGradient(x, y, 0, x, y, R * 0.95)
        warm.addColorStop(0, `rgba(255,214,150,${0.26 * on})`); warm.addColorStop(0.5, `rgba(255,200,130,${0.12 * on})`); warm.addColorStop(0.86, `rgba(255,190,120,${0.07 * on})`); warm.addColorStop(1, "rgba(255,190,120,0)")
        g.fillStyle = warm; g.beginPath(); g.arc(x, y, R, 0, Math.PI * 2); g.fill()
        g.globalCompositeOperation = "source-over"
      }
    },
  }
}

// C · The bulb. The light in the room is failing: it dips and flickers in uneven runs, the edges of
// the room darker than the middle, and once in a while — in a dip — a shape crosses behind the
// slide. Hovering steadies the light a little; a press sets it off flickering.
function bulb(fx) {
  let t = 0, dim = 0, run = 0, next = rand(1.5, 4), shape = null, nextShape = rand(8, 14)
  return {
    busy: () => true,
    step(dt, amount, active) {
      t += dt
      if (active) {
        next -= dt
        if (next < 0) { run = rand(0.3, 1.4); next = rand(fx.pointer.on ? 4 : 2, fx.pointer.on ? 9 : 6) }
        for (const _ of fresh(fx, active)) run = 1.6
        nextShape -= dt
        if (nextShape < 0 && run > 0 && !shape) { shape = {x: -0.15, v: rand(0.35, 0.55), dir: Math.random() < 0.5 ? 1 : -1, h: rand(0.55, 0.8)}; nextShape = rand(10, 18) }
      }
      run = Math.max(0, run - dt)
      const target = run > 0 ? (Math.random() < 0.5 ? rand(0.45, 0.8) : rand(0, 0.25)) : 0.08 + 0.05 * Math.sin(t * 0.7)
      dim += (target - dim) * Math.min(1, dt * (run > 0 ? 30 : 3))
      if (shape) { shape.x += shape.v * dt; if (shape.x > 1.15) shape = null }
    },
    draw(g, alpha) {
      g.globalAlpha = alpha
      // The edges of the room always a little darker.
      const vg = g.createRadialGradient(fx.W / 2, fx.H * 0.45, Math.min(fx.W, fx.H) * 0.25, fx.W / 2, fx.H * 0.45, Math.max(fx.W, fx.H) * 0.75)
      vg.addColorStop(0, "rgba(0,0,0,0)"); vg.addColorStop(1, "rgba(0,0,0,0.6)")
      g.fillStyle = vg; g.fillRect(0, 0, fx.W, fx.H)
      if (shape) {
        // A figure: a soft dark column with a head, crossing behind (under the darkness).
        const px = shape.dir > 0 ? shape.x * fx.W : (1 - shape.x) * fx.W
        const h = (fx.carBottom - fx.carTop) * shape.h, base = fx.carBottom - 30, w = h * 0.22
        g.globalAlpha = 0.55 * alpha
        const body = g.createLinearGradient(px - w, 0, px + w, 0)
        body.addColorStop(0, "rgba(0,0,0,0)"); body.addColorStop(0.5, "rgba(0,0,0,1)"); body.addColorStop(1, "rgba(0,0,0,0)")
        g.fillStyle = body
        g.beginPath(); g.ellipse(px, base - h * 0.42, w, h * 0.42, 0, 0, Math.PI * 2); g.fill()
        g.beginPath(); g.ellipse(px, base - h * 0.9, w * 0.42, w * 0.5, 0, 0, Math.PI * 2); g.fill()
      }
      g.globalAlpha = alpha * dim; g.fillStyle = "rgb(2,1,3)"; g.fillRect(0, 0, fx.W, fx.H)
    },
  }
}

// D · Static. An old tape of something you should not be watching: grain, scanlines, a tracking
// band that rolls up the picture now and then with a torn, colour-split edge; the pointer drags the
// band to where it is; a press glitches the whole picture for a moment.
function tape(fx) {
  let t = 0, band = null, nextBand = rand(2, 5), glitch = 0, lines = null
  const makeLines = () => {
    const c = document.createElement("canvas"); c.width = 4; c.height = 3
    const g = c.getContext("2d"); g.fillStyle = "rgba(0,0,0,0.28)"; g.fillRect(0, 2, 4, 1)
    return c
  }
  return {
    busy: () => true,
    step(dt, amount, active) {
      t += dt
      if (active) {
        nextBand -= dt
        if (nextBand < 0 && !band) { band = {y: fx.H + 40, v: rand(90, 160), h: rand(18, 46)}; nextBand = rand(4, 9) }
        if (fx.pointer.on) { if (!band) band = {y: fx.pointer.y, v: 0, h: 30}; band.y += (fx.pointer.y - band.y) * Math.min(1, dt * 6); band.v = 0 }
        else if (band && band.v === 0) band.v = 120
        for (const _ of fresh(fx, active)) glitch = 0.35
      }
      if (band) { band.y -= band.v * dt; if (band.y < -band.h - 20) band = null }
      glitch = Math.max(0, glitch - dt)
    },
    draw(g, alpha) {
      g.globalAlpha = alpha * 0.9
      const gr = fx.sprites.grains[Math.floor(t * 24) % fx.sprites.grains.length]
      const pat = g.createPattern(gr, "repeat")
      g.save(); g.translate(Math.random() * 128, Math.random() * 128); g.fillStyle = pat; g.fillRect(-128, -128, fx.W + 256, fx.H + 256); g.restore()
      lines ||= g.createPattern(makeLines(), "repeat")
      g.globalAlpha = alpha * 0.8; g.fillStyle = lines; g.fillRect(0, 0, fx.W, fx.H)
      // A slow roll of brightness down the screen, as old sets have.
      const roll = ((t * 40) % (fx.H + 200)) - 100
      const rg = g.createLinearGradient(0, roll - 80, 0, roll + 80)
      rg.addColorStop(0, "rgba(255,255,255,0)"); rg.addColorStop(0.5, `rgba(255,255,255,${0.04 * alpha})`); rg.addColorStop(1, "rgba(255,255,255,0)")
      g.globalAlpha = 1; g.fillStyle = rg; g.fillRect(0, roll - 80, fx.W, 160)
      const tear = (y, h) => {
        for (let k = 0; k < 6; k++) {
          const yy = y + rand(-h / 2, h / 2), off = rand(-30, 30)
          g.globalAlpha = rand(0.15, 0.4) * alpha
          g.fillStyle = Math.random() < 0.5 ? "rgb(255,40,60)" : "rgb(60,220,255)"
          g.fillRect(off + rand(0, fx.W * 0.6), yy, rand(40, fx.W * 0.4), rand(1, 3))
        }
        g.globalAlpha = 0.35 * alpha; g.fillStyle = "rgb(255,255,255)"; g.fillRect(0, y - h / 2, fx.W, 1.5)
        g.globalAlpha = 0.25 * alpha; g.fillStyle = "rgb(0,0,0)"; g.fillRect(0, y - h / 2 + 2, fx.W, h)
      }
      if (band) tear(band.y, band.h)
      if (glitch > 0) for (let i = 0; i < 4; i++) tear(rand(0, fx.H), rand(10, 60))
    },
  }
}

// E · It reaches in. Darkness creeps in from the edges in long fingers that sway and stretch toward
// the middle as if breathing, and pull back from the pointer; a press makes them all flinch away.
function reach(fx) {
  const L = layer(fx, 5)
  let t = 0, flinch = 0
  const fingers = []
  const make = () => {
    fingers.length = 0
    const n = fx.phone ? 9 : 16
    for (let i = 0; i < n; i++) {
      const side = i % 4, along = (Math.floor(i / 4) + rand(0.15, 0.85)) / Math.ceil(n / 4)
      fingers.push({side, along, len: rand(0.18, 0.34), w: rand(18, 38), ph: rand(0, 6), sp: rand(0.25, 0.5), back: 0})
    }
  }
  return {
    busy: () => true,
    step(dt, amount, active) {
      if (!fingers.length || fx.W !== this.w) { this.w = fx.W; make() }
      t += dt
      for (const _ of fresh(fx, active)) flinch = 1
      flinch = Math.max(0, flinch - dt * 0.7)
    },
    draw(g, alpha) {
      const P = fx.pointer, S = Math.min(fx.W, fx.H)
      // The edges themselves, dark.
      const vg = g.createRadialGradient(fx.W / 2, fx.H / 2, S * 0.3, fx.W / 2, fx.H / 2, Math.max(fx.W, fx.H) * 0.7)
      vg.addColorStop(0, "rgba(0,0,0,0)"); vg.addColorStop(1, `rgba(0,0,0,${0.7 * alpha})`)
      g.globalAlpha = 1; g.fillStyle = vg; g.fillRect(0, 0, fx.W, fx.H)
      // The fingers on a small layer, drawn up soft: shadow, not brush strokes.
      L.fit()
      const h = L.g, k = L.k
      h.setTransform(1 / k, 0, 0, 1 / k, 0, 0)
      h.clearRect(0, 0, fx.W, fx.H)
      h.lineCap = "round"; h.strokeStyle = "rgb(0,0,0)"
      for (const f of fingers) {
        // Where it starts on its edge, and the way in.
        let x0, y0, ix, iy
        if (f.side === 0) { x0 = f.along * fx.W; y0 = -10; ix = 0; iy = 1 }
        else if (f.side === 1) { x0 = fx.W + 10; y0 = f.along * fx.H; ix = -1; iy = 0 }
        else if (f.side === 2) { x0 = f.along * fx.W; y0 = fx.H + 10; ix = 0; iy = -1 }
        else { x0 = -10; y0 = f.along * fx.H; ix = 1; iy = 0 }
        const breath = 0.75 + 0.25 * Math.sin(t * f.sp + f.ph)
        let reachLen = S * f.len * breath * (1 - flinch * 0.8)
        // Pulled back as the pointer comes near its tip.
        const tipX = x0 + ix * reachLen, tipY = y0 + iy * reachLen
        const shy = near(P, tipX, tipY, S * 0.35)
        f.back += (shy - f.back) * 0.15
        reachLen *= 1 - f.back * 0.75
        const steps = 14
        for (let k = steps; k >= 1; k--) {
          const p = k / steps
          const px = x0 + ix * reachLen * p + iy * Math.sin(t * 0.9 + f.ph + p * 3) * 14 * p
          const py = y0 + iy * reachLen * p + ix * Math.sin(t * 0.9 + f.ph + p * 3) * 14 * p
          h.globalAlpha = 0.35 + 0.55 * (1 - p)
          h.lineWidth = f.w * 1.6 * (1 - p * 0.8)
          h.beginPath(); h.moveTo(px, py); h.lineTo(px - ix * reachLen / steps, py - iy * reachLen / steps); h.stroke()
        }
      }
      g.globalAlpha = 0.85 * alpha; g.imageSmoothingEnabled = true; g.imageSmoothingQuality = "high"
      g.drawImage(L.c, 0, 0, fx.W, fx.H)
    },
  }
}

Object.assign(EFFECTS, {
  "cry-mist": mist, "cry-drizzle": drizzle, "cry-ripples": ripples,
  "scared-flashlight": flashlight, "scared-bulb": bulb, "scared-tape": tape, "scared-reach": reach,
})

// Mount the real hook on every `[data-lab-fx]` box (each names its effect in `data-mood`).
window.addEventListener("DOMContentLoaded", () => {
  try { localStorage.setItem("roki:fx", "on") } catch {}
  for (const el of document.querySelectorAll("[data-lab-fx]")) {
    const hook = Object.create(MoodFx)
    hook.el = el
    hook.mounted()
    el.labHook = hook
  }
})
