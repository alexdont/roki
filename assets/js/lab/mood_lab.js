// The mood lab (priv/static/lab/moods.html): trial versions of the "Have a good cry" and "Be
// scared" weather, run in the real MoodFx hook beside the current ones. Each is an effect in the
// hook's own shape — `step(dt, amount, active)`, `draw(g, alpha)` — reading what every effect reads
// of the hook (`fx.W`, `fx.H`, `fx.carTop`, `fx.carBottom`, `fx.phone`, `fx.pointer`, `fx.pokes`,
// `fx.sprites`), so the one chosen moves into mood_fx.js as it is.
//
// Built on its own (esbuild → priv/static/lab/mood-lab.js), never part of app.js.
import {MoodFx, EFFECTS, rain, RAIN, crawl, inside, plusWith} from "../mood_fx"

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

// ══ Be scared, more: the new hand plus one thing more ══════════════════════════════════════════
// Each is the reworked red rain (a weeping smear, a dripping handprint on a press) with an extra
// laid on it, which reaches into the rain through `rain(...).api`.
const BLOOD = {...RAIN.scared, weep: 0.08, smearLife: 2.6, palm: "rgba(118,0,10,0.92)"}
function plus(extra) {
  return (fx) => {
    const base = rain(fx, BLOOD), x = extra(fx, base.api)
    return {
      busy: () => true, stats: base.stats,
      step(dt, amount, active) { base.step(dt, amount, active); x.step(dt, amount, active) },
      draw(g, alpha) { g.save(); x.under?.(g, alpha); g.restore(); base.draw(g, alpha); g.save(); x.over?.(g, alpha); g.restore() },
    }
  }
}
// Strokes: when a wipe ends (the hand stops, or leaves), where it went — for what answers a wipe.
function strokes(fx) {
  let cur = null
  return (dt, active, done) => {
    const P = fx.pointer
    if (active && P.on && P.speed > 40) {
      cur ||= {pts: [], still: 0}
      cur.pts.push({x: P.x, y: P.y}); cur.still = 0
    } else if (cur) {
      cur.still += dt
      if (cur.still > 0.25 || !P.on) { if (cur.pts.length > 4) done(cur.pts); cur = null }
    }
  }
}

// 1 · Something on the other side: wipe a clear patch and, now and then, a pale face is right
// behind the glass there for a moment. Rare on purpose (one wipe in four here, to test it).
function otherSide(fx) {
  const L = layer(fx, 3)
  let face = null, last = 0
  const track = strokes(fx)
  return {
    step(dt, amount, active) {
      last += dt
      track(dt, active, (pts) => {
        if (face || last < 4 || Math.random() > 0.25) return
        const c = pts[Math.floor(pts.length / 2)]
        face = {x: c.x, y: c.y + 10, t: 0, dur: 1.3, s: rand(0.9, 1.2)}; last = 0
      })
      if (face) { face.t += dt; if (face.t > face.dur) face = null }
    },
    under(g, alpha) {
      if (!face) return
      const p = face.t / face.dur, a = (p < 0.12 ? p / 0.12 : Math.max(0, 1 - (p - 0.35) / 0.65)) * alpha
      L.fit(); const h = L.g, k = L.k
      h.setTransform(1 / k, 0, 0, 1 / k, 0, 0); h.clearRect(0, 0, fx.W, fx.H)
      h.save(); h.translate(face.x, face.y); h.scale(face.s, face.s)
      const skin = h.createRadialGradient(0, -6, 6, 0, 0, 62)
      skin.addColorStop(0, "rgba(232,226,220,0.95)"); skin.addColorStop(0.7, "rgba(170,164,160,0.7)"); skin.addColorStop(1, "rgba(120,115,112,0)")
      h.fillStyle = skin; h.beginPath(); h.ellipse(0, 0, 44, 60, 0, 0, Math.PI * 2); h.fill()
      h.fillStyle = "rgba(10,6,8,0.95)"
      for (const ex of [-16, 16]) { h.beginPath(); h.ellipse(ex, -10, 9, 12, 0, 0, Math.PI * 2); h.fill() }
      h.beginPath(); h.ellipse(0, 30, 8, 12, 0, 0, Math.PI * 2); h.fill()
      h.restore()
      g.globalAlpha = a; g.imageSmoothingEnabled = true; g.drawImage(L.c, 0, 0, fx.W, fx.H)
    },
  }
}

// 2 · A hand presses back: a beat after your click, a pale hand slaps the glass from the other
// side, mirrored, a little off from yours, blurred by the glass between.
function pressBack(fx, api) {
  const due = []
  return {
    step(dt, amount, active) {
      for (const k of active ? fx.pokes.filter((q) => q.fresh) : []) due.push({x: k.x + rand(-34, 34), y: k.y + rand(-22, 18), t: rand(0.3, 0.55)})
      for (const d of due) d.t -= dt
      for (const d of due.filter((d) => d.t <= 0)) api.stamp(d.x, d.y, {color: "rgba(214,206,200,0.6)", soft: true, mirror: true, drip: false, life: 3.5, scale: 1.08})
      for (let i = due.length - 1; i >= 0; i--) if (due[i].t <= 0) due.splice(i, 1)
    },
  }
}

// 3 · Writing in the blood: hold still after a wipe and words run into the blood near your finger,
// a letter at a time, then drip apart.
function writing(fx, api) {
  const WORDS = ["GET OUT", "BEHIND YOU", "IT SEES YOU", "DON'T LOOK", "LET ME IN", "TOO LATE"]
  let text = null, wiped = 0, still = 0, cool = 0
  return {
    step(dt, amount, active) {
      const P = fx.pointer
      cool -= dt
      if (active && P.on && P.speed > 40) { wiped = 1.5; still = 0 }
      else if (P.on) { still += dt; wiped -= dt * 0.3 }
      if (!text && wiped > 0 && still > 0.6 && cool < 0) {
        const w = WORDS[Math.floor(Math.random() * WORDS.length)]
        text = {w, x: Math.max(20, Math.min(fx.W - 300, P.x - 60)), y: Math.max(60, P.y - 40), t: 0, dripped: false}
        cool = 4; still = 0
      }
      if (text) {
        text.t += dt
        const per = 0.13, done = text.w.length * per
        if (!text.dripped && text.t > done + 0.4) {
          text.dripped = true
          for (let i = 0; i < text.w.length; i++) if (text.w[i] !== " " && Math.random() < 0.6) api.spawn(text.x + (text.at?.[i] || i * 34) + 12 + rand(-4, 4), text.y + 8, rand(2.6, 4.4), true)
        }
        if (text.t > done + 4.5) text = null
      }
    },
    over(g, alpha) {
      if (!text) return
      const per = 0.13, shown = Math.min(text.w.length, Math.floor(text.t / per) + 1), done = text.w.length * per
      const a = (text.t > done + 2.5 ? Math.max(0, 1 - (text.t - done - 2.5) / 2) : 1) * alpha
      g.font = "58px Creepster, 'Oswald', sans-serif"; g.textBaseline = "alphabetic"
      // Each letter where the typeface puts it (measured once), so the word reads as a word.
      text.at ||= [...text.w].map((_, i) => g.measureText(text.w.slice(0, i)).width)
      g.fillStyle = "rgba(185,12,24,0.95)"; g.shadowColor = "rgba(40,0,3,0.8)"; g.shadowBlur = 6
      for (let i = 0; i < shown; i++) {
        const age = text.t - i * per, run = Math.min(1, age * 3)
        g.globalAlpha = a * run
        g.fillText(text.w[i], text.x + text.at[i], text.y + (1 - run) * 6)
      }
    },
  }
}

// 4 · The drops crawl to you: now in mood_fx.js (crawl), the site's Be scared.

// 5 · Your touch cracks the glass: a click leaves a spiderweb crack that blood seeps into and runs
// from; a click near a crack spreads it.
function cracks(fx, api) {
  const all = []
  const arms = (x, y, n, len) => {
    const out = []
    for (let i = 0; i < n; i++) {
      const ang = (i / n) * Math.PI * 2 + rand(-0.2, 0.2), pts = [{x, y}]
      let px = x, py = y, L = len * rand(0.6, 1.2)
      for (let s = 0; s < 6; s++) { const step = L / 6; const a2 = ang + rand(-0.35, 0.35); px += Math.cos(a2) * step; py += Math.sin(a2) * step; pts.push({x: px, y: py}) }
      out.push(pts)
    }
    return out
  }
  return {
    step(dt, amount, active) {
      for (const k of active ? fx.pokes.filter((q) => q.fresh) : []) {
        const nearC = all.find((c) => Math.hypot(c.x - k.x, c.y - k.y) < 90)
        if (nearC) { nearC.lines.push(...arms(k.x, k.y, 6, 110)); nearC.life = 20; nearC.seep = Math.min(nearC.seep, 0.4) }
        else all.push({x: k.x, y: k.y, lines: arms(k.x, k.y, rand(9, 13) | 0, rand(80, 140)), rings: [rand(16, 24), rand(34, 48)], life: 20, seep: 0, dripped: 0})
      }
      for (const c of all) {
        c.life -= dt; c.seep = Math.min(1, c.seep + dt / 3)
        // Blood runs from the crack's lower ends as it seeps in.
        if (c.seep > 0.5 && c.dripped < 4 && Math.random() < dt * 1.5) {
          const down = c.lines.map((l) => l[l.length - 1]).filter((p) => p.y > c.y)
          const p = down[Math.floor(Math.random() * down.length)]
          if (p) { api.spawn(p.x, p.y, rand(2.6, 4), true); c.dripped++ }
        }
      }
      for (let i = all.length - 1; i >= 0; i--) if (all[i].life <= 0) all.splice(i, 1)
    },
    over(g, alpha) {
      for (const c of all) {
        const a = Math.min(1, c.life / 3) * alpha
        g.lineCap = "round"; g.lineJoin = "round"
        const path = (l) => { g.beginPath(); g.moveTo(l[0].x, l[0].y); for (const p of l.slice(1)) g.lineTo(p.x, p.y); g.stroke() }
        // Blood in the crack, spreading from the middle out.
        g.strokeStyle = "rgba(120,0,10,0.85)"; g.lineWidth = 3
        for (const l of c.lines) { const n = Math.max(2, Math.round(l.length * c.seep)); g.globalAlpha = a * 0.8; path(l.slice(0, n)) }
        // The crack itself: a bright hairline with a dark edge.
        g.strokeStyle = "rgba(0,0,0,0.5)"; g.lineWidth = 2.2; g.globalAlpha = a; for (const l of c.lines) path(l)
        g.strokeStyle = "rgba(235,235,245,0.7)"; g.lineWidth = 0.9; for (const l of c.lines) path(l)
        for (const r of c.rings) {
          g.beginPath()
          for (let i = 0; i <= 14; i++) { const ang = (i / 14) * Math.PI * 2, rr = r * (0.85 + ((i * 7) % 5) / 15); i ? g.lineTo(c.x + Math.cos(ang) * rr, c.y + Math.sin(ang) * rr) : g.moveTo(c.x + Math.cos(ang) * rr, c.y + Math.sin(ang) * rr) }
          g.globalAlpha = a * 0.6; g.stroke()
        }
        g.globalAlpha = a * 0.9; g.fillStyle = "rgba(235,235,245,0.8)"; g.beginPath(); g.arc(c.x, c.y, 2.5, 0, Math.PI * 2); g.fill()
      }
    },
  }
}

// 6 · A handprint from inside: now in mood_fx.js (inside), the site's Be scared.

// 7 · The rain stops: all at once it stops and it is quiet; then one drop; then it comes back harder.
function hush(fx, api) {
  let next = rand(5, 8), phase = null, t = 0
  return {
    step(dt, amount, active) {
      if (!active) return
      t += dt; next -= dt
      if (!phase && next < 0) { phase = "quiet"; t = 0; api.rate(0) }
      if (phase === "quiet" && t > 2.8) { phase = "one"; t = 0; api.streak(fx.W * rand(0.35, 0.65)) }
      if (phase === "one" && t > 1.1) { phase = "hard"; t = 0; api.rate(2.2) }
      if (phase === "hard" && t > 4) { phase = null; api.rate(1); next = rand(12, 18) }
    },
    over(g, alpha) {
      // While it is quiet, the room seems to hold its breath: a little darker.
      if (phase === "quiet" || phase === "one") { g.globalAlpha = 0.22 * alpha * Math.min(1, t * 2); g.fillStyle = "#000"; g.fillRect(0, 0, fx.W, fx.H) }
    },
  }
}

// 8 · Lightning: a double flash, and in the first a figure stands behind the rain — not there in
// the second.
function lightning(fx) {
  const L = layer(fx, 2)
  let next = rand(3, 5), t = -1, fig = null
  return {
    step(dt, amount, active) {
      if (!active) return
      next -= dt
      if (next < 0 && t < 0) { t = 0; next = rand(9, 15); fig = {x: rand(fx.W * 0.25, fx.W * 0.75), h: (fx.carBottom - fx.carTop) * rand(0.55, 0.75)} }
      if (t >= 0) { t += dt; if (t > 0.9) t = -1 }
    },
    under(g, alpha) {
      if (t < 0) return
      const f1 = t < 0.18 ? 1 - t / 0.18 : 0, f2 = t > 0.32 && t < 0.62 ? 1 - (t - 0.32) / 0.3 : 0
      const f = Math.max(f1, f2)
      if (f <= 0) return
      g.globalAlpha = f * 0.55 * alpha; g.fillStyle = "rgb(225,230,255)"; g.fillRect(0, 0, fx.W, fx.H)
      if (f1 > 0 && fig) {
        // A person standing still, arms down, a little soft at the edges (rain between).
        L.fit(); const h = L.g, k = L.k
        h.setTransform(1 / k, 0, 0, 1 / k, 0, 0); h.clearRect(0, 0, fx.W, fx.H)
        const H = fig.h, x = fig.x, foot = fx.carBottom - 10, u = H / 100
        const P = (dx, dy) => [x + dx * u, foot - dy * u]
        h.fillStyle = "rgb(6,6,12)"
        h.beginPath(); h.ellipse(...P(0, 92), 6.2 * u, 7.6 * u, 0, 0, Math.PI * 2); h.fill()
        h.beginPath()
        h.moveTo(...P(-3, 84)); h.lineTo(...P(3, 84))
        h.quadraticCurveTo(...P(14, 82), ...P(15, 76))      // shoulder
        h.lineTo(...P(17, 46)); h.lineTo(...P(13, 44))      // arm, hand
        h.lineTo(...P(11, 70)); h.lineTo(...P(9, 50))       // inside of the arm, hip
        h.lineTo(...P(8, 2)); h.lineTo(...P(2, 2)); h.lineTo(...P(0.5, 44))   // leg
        h.lineTo(...P(-0.5, 44)); h.lineTo(...P(-2, 2)); h.lineTo(...P(-8, 2))
        h.lineTo(...P(-9, 50)); h.lineTo(...P(-11, 70)); h.lineTo(...P(-13, 44)); h.lineTo(...P(-17, 46))
        h.lineTo(...P(-15, 76)); h.quadraticCurveTo(...P(-14, 82), ...P(-3, 84))
        h.fill()
        g.globalAlpha = f1 * 0.9 * alpha; g.imageSmoothingEnabled = true; g.drawImage(L.c, 0, 0, fx.W, fx.H)
      }
    },
  }
}

// The chosen mix: the red rain without the wipe; the drops crawl to the pointer and pool; hands
// slap the glass from inside and slide down, left and right in turn, each its own.
Object.assign(EFFECTS, {
  "scared-final": EFFECTS.scared,
  "scared-face": plus(otherSide), "scared-pressback": plus(pressBack), "scared-writing": plus(writing),
  "scared-crawl": plus(crawl), "scared-crack": plus(cracks), "scared-inside": plus(inside),
  "scared-hush": plus(hush), "scared-lightning": plus(lightning),
})

// ══ Have a good cry: the hand, six ways ═════════════════════════════════════════════════════
// The rain on glass without the wipe, and something gentler answering the hand. Fog is a layer at
// a quarter size: misted white, a finger clears it, it mists back.
function fogLayer(fx) {
  const L = layer(fx, 2), MIST = "rgb(206,216,232)"
  return {
    L,
    // Breathe on a spot: fog there (a soft round).
    breathe(x, y, r, a) {
      const g = L.g, k = L.k, gr = g.createRadialGradient(x / k, y / k, 0, x / k, y / k, r / k)
      gr.addColorStop(0, `rgba(206,216,232,${a})`); gr.addColorStop(1, "rgba(206,216,232,0)")
      g.fillStyle = gr; g.beginPath(); g.arc(x / k, y / k, r / k, 0, Math.PI * 2); g.fill()
    },
    clear(x, y, r) {
      const g = L.g, k = L.k, gr = g.createRadialGradient(x / k, y / k, 0, x / k, y / k, r / k)
      gr.addColorStop(0, "rgba(0,0,0,1)"); gr.addColorStop(0.6, "rgba(0,0,0,0.85)"); gr.addColorStop(1, "rgba(0,0,0,0)")
      g.globalCompositeOperation = "destination-out"; g.fillStyle = gr
      g.beginPath(); g.arc(x / k, y / k, r / k, 0, Math.PI * 2); g.fill(); g.globalCompositeOperation = "source-over"
    },
    // Everything fogged fades (the glass dries) at `rate` a second.
    dry(dt, rate) {
      const g = L.g; g.globalCompositeOperation = "destination-out"; g.globalAlpha = Math.min(1, dt * rate)
      g.fillRect(0, 0, L.c.width, L.c.height); g.globalAlpha = 1; g.globalCompositeOperation = "source-over"
    },
    fit: () => L.fit(),
    // Drawn through a blur, so the fog has no edge and no pixels; light, as breath on glass is.
    draw(g, a) { g.save(); g.globalAlpha = a; g.filter = "blur(6px)"; g.imageSmoothingEnabled = true; g.imageSmoothingQuality = "high"; g.drawImage(L.c, 0, 0, fx.W, fx.H); g.restore() },
    MIST,
  }
}

// 1 · Write in the fog: hold the pointer still and your breath fogs a patch; move, and your finger
// writes a clear line through the fog, which slowly mists back over and then dries away.
function fogWrite(fx) {
  const F = fogLayer(fx)
  let still = 0, lastP = null, wrote = 0
  return {
    step(dt, amount, active) {
      F.fit()
      const P = fx.pointer
      if (active && P.on) {
        if (P.speed < 25) { still += dt; if (still > 0.25) {
          // Breath spreads unevenly: a few soft puffs around the pointer, not one round.
          for (let i = 0; i < 3; i++) { const a = rand(0, Math.PI * 2), d = rand(0, 60); F.breathe(P.x + Math.cos(a) * d, P.y + Math.sin(a) * d * 0.8, rand(45, 85) * (fx.phone ? 0.8 : 1), Math.min(0.05, dt * 0.6)) }
        } }
        else {
          still = 0
          // A finger through the fog — only where there is fog to write in (it clears what is there).
          const pts = P.path && P.path.length ? P.path : [{x: P.x, y: P.y}]
          for (const q of pts) { F.clear(q.x, q.y, 9); if (lastP) for (let i = 1; i < 4; i++) F.clear(lastP.x + (q.x - lastP.x) * i / 4, lastP.y + (q.y - lastP.y) * i / 4, 9); lastP = q }
          wrote = 2
        }
      } else { still = 0; lastP = null }
      if (!P.on || P.speed >= 25) lastP = P.on ? lastP : null
      // The writing mists back over in a few seconds; the fog itself dries slowly.
      wrote -= dt
      F.dry(dt, wrote > 0 ? 0.015 : 0.05)
    },
    over(g, alpha) { F.draw(g, alpha * 0.5) },
  }
}

// 2 · Tears gather to your hand: like the drops crawling in Be scared, but slower and softer —
// drops drift to a pointer held still and become one big tear that rolls when you move off.
const tearsGather = (fx, api) => {
  const c = crawl(fx, api)
  return { step(dt, amount, active) { c.step(dt * 0.6, amount, active) } }
}

// 3 · Rain parts around you: the pointer is shelter — streaks fall round it, drops slide aside,
// a calm clear circle follows you, slowly.
function shelter(fx, api) {
  let sx = 0, sy = 0, on = 0
  return {
    step(dt, amount, active) {
      const P = fx.pointer
      on += ((active && P.on ? 1 : 0) - on) * Math.min(1, dt * 2)
      sx += (P.x - sx) * Math.min(1, dt * 2.5); sy += (P.y - sy) * Math.min(1, dt * 2.5)
      if (on < 0.05) return
      const R = (fx.phone ? 80 : 120) * on
      for (const d of api.drops()) {
        if (d.dead) continue
        const dx = d.x - sx, dy = d.y - sy, dist = Math.hypot(dx, dy)
        if (dist < R && dist > 0.1) { const push = (R - dist) * Math.min(1, dt * 3); d.x += dx / dist * push; d.y += dy / dist * push * 0.6 }
      }
      for (const st of api.streaks()) {
        const dx = st.x - sx, dy = st.y - sy, dist = Math.hypot(dx, dy)
        if (dist < R * 1.2 && dist > 0.1) st.x += dx / dist * (R * 1.2 - dist) * Math.min(1, dt * 6)
      }
    },
    under(g, alpha) {
      if (on < 0.05) return
      const R = (fx.phone ? 80 : 120) * on
      const gr = g.createRadialGradient(sx, sy, R * 0.3, sx, sy, R * 1.1)
      gr.addColorStop(0, `rgba(200,215,240,${0.05 * on * alpha})`); gr.addColorStop(0.75, `rgba(200,215,240,${0.03 * on * alpha})`); gr.addColorStop(1, "rgba(200,215,240,0)")
      g.fillStyle = gr; g.beginPath(); g.arc(sx, sy, R * 1.1, 0, Math.PI * 2); g.fill()
      // The edge of the shelter: a faint wet rim where the rain turns aside.
      g.globalAlpha = 0.22 * on * alpha; g.strokeStyle = "rgb(210,224,248)"; g.lineWidth = 1.2
      g.beginPath(); g.arc(sx, sy, R, 0, Math.PI * 2); g.stroke()
    },
  }
}

// 4 · A hand on the glass from your side: a click leaves a soft, warm, misty print — a palm laid on
// a cold window — that fogs over slowly; a couple of drops run from it.
const MISTY = "rgba(214,224,240,0.55)"
function warmPrint(fx, api) {
  let left = Math.random() < 0.5
  return {
    step(dt, amount, active) {
      for (const k of active ? fx.pokes.filter((q) => q.fresh) : []) {
        left = !left
        api.stamp(k.x, k.y, {color: MISTY, soft: true, mirror: left, vary: true, scale: rand(0.95, 1.1), life: 9, drip: false})
        for (let i = 0; i < 2; i++) api.spawn(k.x + rand(-18, 18), k.y + rand(18, 32), rand(3, 4.4), true)
      }
    },
  }
}

// 5 · Someone on the other side: now and then, after your print, a second faint hand comes to the
// glass from outside against yours — slowly, softly — and fades.
function reachBack(fx, api) {
  const due = []
  return {
    step(dt, amount, active) {
      for (const k of active ? fx.pokes.filter((q) => q.fresh) : []) if (Math.random() < 0.5) due.push({x: k.x + rand(-14, 14), y: k.y + rand(-10, 10), t: rand(1.2, 2)})
      for (const d of due) d.t -= dt
      for (const d of due.filter((d) => d.t <= 0)) api.stamp(d.x, d.y, {color: "rgba(255,226,200,0.32)", soft: true, mirror: true, vary: true, scale: rand(0.85, 0.98), life: 6, drip: false})
      for (let i = due.length - 1; i >= 0; i--) if (due[i].t <= 0) due.splice(i, 1)
    },
  }
}

// 6 · A heart in the fog: draw a loop and it becomes a heart misted on the glass, which drips and
// fades.
function fogHeart(fx, api) {
  const hearts = []
  let trail = [], turned = 0, lastA = null
  return {
    step(dt, amount, active) {
      const P = fx.pointer
      if (active && P.on && P.speed > 15) {
        for (const q of (P.path && P.path.length ? P.path : [{x: P.x, y: P.y}])) {
          const l = trail[trail.length - 1]
          if (!l || Math.hypot(q.x - l.x, q.y - l.y) > 6) {
            if (l && trail.length > 1) {
              const a0 = trail[trail.length - 2], ang0 = Math.atan2(l.y - a0.y, l.x - a0.x), ang1 = Math.atan2(q.y - l.y, q.x - l.x)
              let d = ang1 - ang0; d = Math.atan2(Math.sin(d), Math.cos(d)); turned += d
            }
            trail.push({x: q.x, y: q.y}); if (trail.length > 120) trail.shift()
          }
        }
        // Once round (either way): a heart where the loop was.
        if (Math.abs(turned) > Math.PI * 1.6) {
          const xs = trail.map((q) => q.x), ys = trail.map((q) => q.y)
          const cx = (Math.min(...xs) + Math.max(...xs)) / 2, cy = (Math.min(...ys) + Math.max(...ys)) / 2
          const size = Math.max(40, Math.min(110, (Math.max(...xs) - Math.min(...xs) + Math.max(...ys) - Math.min(...ys)) / 4))
          hearts.push({x: cx, y: cy, s: size, age: 0, life: 6, dripped: 0})
          trail = []; turned = 0; lastA = null
        }
      } else { trail = []; turned = 0; lastA = null }
      for (const h of hearts) {
        h.age += dt
        if (h.age > 1 && h.dripped < 3 && Math.random() < dt * 1.2) { api.spawn(h.x + rand(-0.6, 0.6) * h.s, h.y + h.s * 0.6, rand(2.6, 3.8), true); h.dripped++ }
      }
      for (let i = hearts.length - 1; i >= 0; i--) if (hearts[i].age > hearts[i].life) hearts.splice(i, 1)
    },
    over(g, alpha) {
      for (const h of hearts) {
        const a = Math.min(1, h.age * 3) * Math.min(1, (h.life - h.age) / 2) * alpha
        g.save(); g.translate(h.x, h.y); g.scale(h.s / 50, h.s / 50)
        g.beginPath(); g.moveTo(0, 18)
        g.bezierCurveTo(-34, -6, -26, -38, 0, -18); g.bezierCurveTo(26, -38, 34, -6, 0, 18)
        g.lineWidth = 9; g.lineJoin = "round"; g.strokeStyle = MISTY; g.globalAlpha = a * 0.9; g.stroke()
        g.restore()
      }
    },
  }
}

const TEARS = {...RAIN.cry, noWipe: true}
Object.assign(EFFECTS, {
  "cry-1": plusWith(TEARS, fogWrite), "cry-2": plusWith(TEARS, tearsGather), "cry-3": plusWith(TEARS, shelter),
  "cry-4": plusWith(TEARS, warmPrint), "cry-5": plusWith(TEARS, warmPrint, reachBack), "cry-6": plusWith(TEARS, fogHeart),
  "cry-mix": plusWith(TEARS, tearsGather, warmPrint, fogWrite),
})

// The hand, reworked: what the finger wipes weeps down the glass (tears; a bleeding smear that
// lasts longer); a press on the scared one leaves a handprint that drips.
Object.assign(EFFECTS, {
  "cry-weep": (fx) => rain(fx, {...RAIN.cry, weep: 0.05}),
  "scared-weep": (fx) => rain(fx, {...RAIN.scared, weep: 0.08, smearLife: 2.6, palm: "rgba(118,0,10,0.92)"}),

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
