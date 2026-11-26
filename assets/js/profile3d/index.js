// The profile's 3D showcase (the profile lab's, /lab/profile3d.html, made real): the favourite
// shelves and the recently watched as turning rings of DVD cases (manga as books), the ratings as
// piles of cases, the map as a globe, and an opened title as a case that turns to you and opens.
// Bundled on its own (esbuild → priv/static/vendor/profile3d.js, with three.js, d3-geo and
// topojson-client) and loaded by the ProfileShowcase hook only when a device chooses 3D.
import * as THREE from "three"
import { RoundedBoxGeometry } from "three/examples/jsm/geometries/RoundedBoxGeometry.js"
import { feature } from "topojson-client"
import * as d3 from "d3-geo"

let OPEN = () => {}             // opens a title full screen (the hook's)
let data = { ratings: {}, history: [] }
let P = { name: "" }
let C = { counts: {}, names: {} }, cmax = 1
const heat = (n) => n ? 0.25 + 0.75 * Math.log(n + 1) / Math.log(cmax + 1) : 0
const watchedIn = (code) => `/u/${encodeURIComponent(P.name)}/watched?country=${code}`
const atRating = (score, k) => `/u/${encodeURIComponent(P.name)}/watched?rating=${Math.trunc(score)}` + ({ movie: "&kind=movie", tv: "&kind=tv", mal: "&kind=anime" }[k] || "")
let R = {}
const W = 1.35, H = 1.9, D = 0.14, LID = 0.028
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c])
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

// ── colours from a poster (OKLCH buckets, as the other labs) ─────────────────────────────────
function oklch(r, g, b) {
  const l = (c) => (c /= 255) <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  const [R, G, B] = [l(r), l(g), l(b)]
  const L = Math.cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B), M = Math.cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B), S = Math.cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B)
  const a = 1.9779984951 * L - 2.428592205 * M + 0.4505937099 * S, bb = 0.0259040371 * L + 0.7827717662 * M - 0.808675766 * S
  return { l: 0.2104542553 * L + 0.793617785 * M - 0.0040720468 * S, c: Math.hypot(a, bb), h: (Math.atan2(bb, a) * 180 / Math.PI + 360) % 360 }
}
function paletteOf(img) {
  try {
    const cv = document.createElement("canvas"); cv.width = 24; cv.height = 36
    const g = cv.getContext("2d", { willReadFrequently: true }); g.drawImage(img, 0, 0, 24, 36)
    const d = g.getImageData(0, 0, 24, 36).data, buckets = new Map()
    for (let i = 0; i < d.length; i += 4) {
      const o = oklch(d[i], d[i + 1], d[i + 2]); if (o.l < 0.12 || o.l > 0.95 || o.c < 0.03) continue
      const k = Math.round(o.h / 30), b = buckets.get(k) || { n: 0, c: 0, x: 0, y: 0 }
      b.n++; b.c += o.c; b.x += Math.cos(o.h * Math.PI / 180); b.y += Math.sin(o.h * Math.PI / 180); buckets.set(k, b)
    }
    const list = [...buckets.values()].map((b) => ({ n: b.n, c: b.c / b.n, h: (Math.atan2(b.y, b.x) * 180 / Math.PI + 360) % 360 })).sort((a, b) => b.n - a.n)
    const main = list[0] || { h: 300, c: 0.02 }, lively = list.filter((b) => b.n > 12).sort((a, b) => b.c - a.c)[0] || main
    return pal(main, lively)
  } catch { return pal({ h: 300, c: 0.02 }, { h: 30, c: 0.12 }) }
}
function pal(main, lively) {
  const css = (l, c, h) => `oklch(${l}% ${c} ${Math.round(h)})`
  return { spine: css(42, Math.min(Math.max(main.c, 0.04), 0.13).toFixed(3), main.h), ink: css(95, 0.03, main.h),
           light: css(78, Math.min(Math.max(lively.c, 0.08), 0.16).toFixed(3), lively.h), ground: css(20, Math.min(main.c, 0.06).toFixed(3), main.h) }
}
const toColor = (() => { const c = document.createElement("canvas").getContext("2d"); return (css) => { c.fillStyle = "#000"; c.fillStyle = css; c.fillRect(0, 0, 1, 1); const [r, g, b] = c.getImageData(0, 0, 1, 1).data; return new THREE.Color().setRGB(r / 255, g / 255, b / 255, THREE.SRGBColorSpace) } })()

// One picture per address for the whole page: the image, its texture and its palette.
const pictures = new Map()
function picture(url) {
  if (!url) return Promise.resolve(null)
  if (!pictures.has(url)) pictures.set(url, new Promise((res) => {
    const img = new Image(); img.crossOrigin = "anonymous"; img.decoding = "async"
    img.onload = () => {
      let tex = null
      if (THREE) { tex = new THREE.Texture(img); tex.colorSpace = THREE.SRGBColorSpace; tex.anisotropy = 8; tex.needsUpdate = true }
      res({ img, tex, pal: paletteOf(img) })
    }
    img.onerror = () => res(null)
    img.src = url
  }))
  return pictures.get(url)
}
function spineTexture(item, p) {
  const c = document.createElement("canvas"); c.width = 72; c.height = 980
  const g = c.getContext("2d")
  g.fillStyle = p.spine; g.fillRect(0, 0, 72, 980)
  g.fillStyle = "#ffffff18"; g.fillRect(4, 0, 2, 980); g.fillStyle = "#00000040"; g.fillRect(64, 0, 8, 980)
  g.save(); g.translate(46, 900); g.rotate(-Math.PI / 2); g.fillStyle = p.ink; g.font = "600 34px Outfit"
  let t = item.title || ""; while (g.measureText(t).width > 760 && t.length > 3) t = t.slice(0, -2)
  if (t !== item.title) t = t.trimEnd() + "…"
  g.fillText(t, 0, 0); g.restore()
  if (item.year) { g.save(); g.translate(46, 960); g.rotate(-Math.PI / 2); g.globalAlpha = 0.75; g.font = "500 22px 'JetBrains Mono'"; g.fillStyle = p.ink; g.fillText(item.year, 0, 0); g.restore() }
  const tex = new THREE.CanvasTexture(c); tex.colorSpace = THREE.SRGBColorSpace; tex.anisotropy = 4
  return tex
}

// ── geometry and materials, shared by every stage ──────────────────────────────────────────
let plastic, inner, sleeveMat, hubMat, trayGeo, lidGeo, slimGeo, faceGeo, spineGeo, discGeo, hubGeo
if (THREE) {
  plastic = new THREE.MeshStandardMaterial({ color: 0x101012, roughness: 0.32, metalness: 0.05 })
  inner = new THREE.MeshStandardMaterial({ color: 0x1b1b20, roughness: 0.6 })
  sleeveMat = new THREE.MeshPhysicalMaterial({ color: 0xffffff, roughness: 0.06, transparent: true, opacity: 0.1, clearcoat: 1, clearcoatRoughness: 0.05 })
  hubMat = new THREE.MeshStandardMaterial({ color: 0xc9ccd4, roughness: 0.25, metalness: 0.9 })
  trayGeo = new RoundedBoxGeometry(W, H, D - LID, 2, 0.02), lidGeo = new RoundedBoxGeometry(W, H, LID, 2, 0.012)
  slimGeo = new RoundedBoxGeometry(W, H, D, 2, 0.02)
  faceGeo = new THREE.PlaneGeometry(W - 0.04, H - 0.04), spineGeo = new THREE.PlaneGeometry(D, H - 0.01)
  discGeo = new THREE.CircleGeometry(0.6, 64), hubGeo = new THREE.RingGeometry(0.07, 0.17, 48)
}

// A full case (opens): tray, a lid on the spine's hinge with the cover under a sleeve, a disc.
// A manga is a book, not a disc case: a tankōbon (≈ 13 × 18 cm, the page block cream, a soft cover
// that opens like a book's), the same shape of object as a case (`hinge`, `cover`, `spine`, `back`)
// so the shelves and the viewer move it the same way. Open, the inside of the cover is the cover
// art again (a jacket's flap) and the first page carries the title, set like a title page.
const BW = 1.3, BH = 1.84, BD = 0.22, BC = 0.012
let paper, pageEdge
function book(item, idx) {
  paper ||= new THREE.MeshStandardMaterial({ color: 0xf1ead8, roughness: 0.9 })
  pageEdge ||= new THREE.MeshStandardMaterial({ map: edgeTexture(), roughness: 0.95 })
  const g = new THREE.Group()
  // The page block, a little inside the cover on three sides.
  const block = new THREE.Mesh(new THREE.BoxGeometry(BW - 0.03, BH - 0.04, BD - 2 * BC), [pageEdge, paper, pageEdge, pageEdge, paper, paper])
  block.position.x = 0.012; block.castShadow = true; g.add(block)
  // The first page, its title set on it (made when the book is dressed).
  const first = new THREE.Mesh(new THREE.PlaneGeometry(BW - 0.07, BH - 0.08), paper.clone())
  first.position.set(0.012, 0, (BD - 2 * BC) / 2 + 0.001); g.add(first)
  // The back cover and the spine (the spine flat against the block's left side).
  const backC = new THREE.Mesh(new THREE.BoxGeometry(BW, BH, BC), new THREE.MeshStandardMaterial({ color: 0x333333, roughness: 0.6 }))
  backC.position.z = -BD / 2 + BC / 2; backC.castShadow = true; g.add(backC)
  const spine = new THREE.Mesh(new THREE.PlaneGeometry(BD, BH), new THREE.MeshStandardMaterial({ color: 0x222222, roughness: 0.55 }))
  spine.rotation.y = -Math.PI / 2; spine.position.x = -BW / 2 - 0.001; g.add(spine)
  // The front cover on a hinge at the spine.
  const hinge = new THREE.Group(); hinge.position.set(-BW / 2, 0, BD / 2 - BC); g.add(hinge)
  const board = new THREE.Mesh(new THREE.BoxGeometry(BW, BH, BC), new THREE.MeshStandardMaterial({ color: 0x2a2a2a, roughness: 0.6 }))
  board.position.set(BW / 2, 0, BC / 2); board.castShadow = true; hinge.add(board)
  const cover = new THREE.Mesh(new THREE.PlaneGeometry(BW, BH), new THREE.MeshStandardMaterial({ color: 0x2a2a2a, roughness: 0.55 }))
  cover.position.set(BW / 2, 0, BC + 0.001); hinge.add(cover)
  const flap = new THREE.Mesh(new THREE.PlaneGeometry(BW - 0.02, BH - 0.02), paper.clone())
  flap.rotation.y = Math.PI; flap.position.set(BW / 2, 0, -0.001); hinge.add(flap)
  g.traverse((m) => { m.userData.idx = idx })
  const c = { item, idx, g, hinge, cover, spine, back: backC, first, flap, full: true, book: true, disc: null }
  dress(c)
  return c
}
// The page edges: fine lines of paper.
function edgeTexture() {
  const c = document.createElement("canvas"); c.width = 8; c.height = 128
  const g = c.getContext("2d"); g.fillStyle = "#eee6d2"; g.fillRect(0, 0, 8, 128)
  for (let y = 0; y < 128; y += 2) { g.fillStyle = `rgba(150,135,110,${0.12 + Math.random() * 0.12})`; g.fillRect(0, y, 8, 1) }
  const t = new THREE.CanvasTexture(c); t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(1, 6); t.colorSpace = THREE.SRGBColorSpace
  return t
}
// The first page: the title and its authors, set quietly on cream paper.
function titlePage(item, pal) {
  const c = document.createElement("canvas"); c.width = 520; c.height = 736
  const g = c.getContext("2d")
  g.fillStyle = "#f3ecdb"; g.fillRect(0, 0, 520, 736)
  g.fillStyle = pal ? pal.spine : "#333"; g.fillRect(60, 210, 400, 3)
  g.fillStyle = "#2a2622"; g.textAlign = "center"
  let size = 52; g.font = `italic 400 ${size}px "Instrument Serif", serif`
  const words = (item.title || "").split(" "), lines = []; let line = ""
  for (const w of words) { const t = line ? line + " " + w : w; if (g.measureText(t).width > 400 && line) { lines.push(line); line = w } else line = t }
  if (line) lines.push(line)
  lines.slice(0, 4).forEach((l, i) => g.fillText(l, 260, 290 + i * 60))
  const au = item.authors
  if (au && au.length) { g.font = '500 20px "Outfit"'; g.fillStyle = "#6b625a"; g.fillText(au.join(" · "), 260, 300 + lines.length * 60 + 30) }
  g.fillStyle = pal ? pal.spine : "#333"; g.fillRect(230, 640, 60, 3)
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 4
  return t
}

function fullCase(item, idx) {
  if (item.type === "manga") return book(item, idx)
  const g = new THREE.Group()
  const tray = new THREE.Mesh(trayGeo, plastic); tray.position.z = -LID / 2; tray.castShadow = true; g.add(tray)
  const trayFace = new THREE.Mesh(faceGeo, inner); trayFace.position.z = -LID / 2 + (D - LID) / 2 + 0.001; g.add(trayFace)
  const disc = new THREE.Group(); disc.position.z = trayFace.position.z + 0.004
  const discFace = new THREE.Mesh(discGeo, new THREE.MeshStandardMaterial({ color: 0x777777, roughness: 0.3, metalness: 0.5 })); disc.add(discFace)
  const hub = new THREE.Mesh(hubGeo, hubMat); hub.position.z = 0.002; disc.add(hub); g.add(disc)
  const back = new THREE.Mesh(faceGeo, plastic.clone()); back.rotation.y = Math.PI; back.position.z = -D / 2 - 0.001; g.add(back)
  const hinge = new THREE.Group(); hinge.position.set(-W / 2, 0, (D - LID) / 2); g.add(hinge)
  const lid = new THREE.Mesh(lidGeo, plastic); lid.position.set(W / 2, 0, LID / 2); lid.castShadow = true; hinge.add(lid)
  const cover = new THREE.Mesh(faceGeo, new THREE.MeshStandardMaterial({ color: 0x2a2a2a, roughness: 0.55 })); cover.position.set(W / 2, 0, LID + 0.001); hinge.add(cover)
  const sleeve = new THREE.Mesh(faceGeo, sleeveMat); sleeve.position.set(W / 2, 0, LID + 0.004); hinge.add(sleeve)
  const lidIn = new THREE.Mesh(faceGeo, inner); lidIn.rotation.y = Math.PI; lidIn.position.set(W / 2, 0, -0.001); hinge.add(lidIn)
  const spine = new THREE.Mesh(spineGeo, new THREE.MeshStandardMaterial({ color: 0x222222, roughness: 0.45 })); spine.rotation.y = -Math.PI / 2; spine.position.x = -W / 2 - 0.0015; g.add(spine)
  g.traverse((m) => { m.userData.idx = idx })
  const c = { item, idx, g, hinge, disc, discFace, cover, spine, back, full: true }
  dress(c)
  return c
}
// A slim case for the wall: a body and the cover (hundreds of them; the full one is made when one is taken out).
function slimCase(item, idx) {
  const g = new THREE.Group()
  const body = new THREE.Mesh(slimGeo, plastic); g.add(body)
  const cover = new THREE.Mesh(faceGeo, new THREE.MeshStandardMaterial({ color: 0x232026, roughness: 0.55 })); cover.position.z = D / 2 + 0.002; g.add(cover)
  const sleeve = new THREE.Mesh(faceGeo, sleeveMat); sleeve.position.z = D / 2 + 0.005; g.add(sleeve)
  g.traverse((m) => { m.userData.idx = idx })
  return { item, idx, g, cover, slim: true }
}
function dress(c) {
  return picture(c.item.poster).then((p) => {
    if (!p) return
    c.pal = p.pal
    c.cover.material = new THREE.MeshStandardMaterial({ map: p.tex, roughness: 0.5 })
    if (c.spine) document.fonts.ready.then(() => { c.spine.material = new THREE.MeshStandardMaterial({ map: spineTexture(c.item, p.pal), roughness: 0.45 }) })
    if (c.back) c.back.material.color = toColor(p.pal.spine).multiplyScalar(0.6)
    if (c.book) {
      c.back.material.color = toColor(p.pal.spine)
      document.fonts.ready.then(() => { c.first.material = new THREE.MeshStandardMaterial({ map: titlePage(c.item, p.pal), roughness: 0.9 }) })
      const t = p.tex.clone(); t.needsUpdate = true
      c.flap.material = new THREE.MeshStandardMaterial({ map: t, roughness: 0.7, color: 0x9a9a9a })
    }
  })
}
function discArt(c) {
  if (c.discLoaded || c.book) return; c.discLoaded = true
  const url = c.item.backdrop || c.item.poster
  picture(url).then((p) => {
    if (!p) return
    const tex = p.tex.clone(); tex.needsUpdate = true
    const a = p.img.width / p.img.height
    if (a > 1) { tex.repeat.set(1 / a, 1); tex.offset.set((1 - 1 / a) / 2, 0) } else { tex.repeat.set(1, a); tex.offset.set(0, (1 - a) / 2) }
    c.discFace.material = new THREE.MeshStandardMaterial({ map: tex, roughness: 0.25, metalness: 0.35 })
  })
}

// ── springs ─────────────────────────────────────────────────────────────────────────────────
function spring(x, v, t, dt, k = 140) { const c = 2 * Math.sqrt(k) * 0.62; v += ((t - x) * k - v * c) * dt; return [x + v * dt, v] }
function motion(c) {
  Object.assign(c, { pos: new THREE.Vector3(0, -8, 0), vel: new THREE.Vector3(), tpos: new THREE.Vector3(), rot: new THREE.Vector3(), rvel: new THREE.Vector3(), trot: new THREE.Vector3(), lid: 0, lvel: 0, tlid: 0, spin: 0, hover: 0, thover: 0 })
  return c
}
function step(c, dt) {
  for (const ax of ["x", "y", "z"]) { ;[c.pos[ax], c.vel[ax]] = spring(c.pos[ax], c.vel[ax], c.tpos[ax], dt); ;[c.rot[ax], c.rvel[ax]] = spring(c.rot[ax], c.rvel[ax], c.trot[ax], dt, 110) }
  c.hover += (c.thover - c.hover) * (1 - Math.exp(-dt * 14))
  c.g.position.copy(c.pos); c.g.rotation.set(c.rot.x, c.rot.y, c.rot.z, "YXZ")
  if (c.full) { ;[c.lid, c.lvel] = spring(c.lid, c.lvel, c.tlid, dt, 70); c.hinge.rotation.y = c.lid; if (c.disc && c.lid < -0.4) { c.spin += dt * 2.2; c.disc.rotation.z = -c.spin } }
}

// ── a stage: one canvas, its scene and lights, the cases in an arrangement ────────────────
let stages = []
class Stage {
  constructor(el, opts) {
    this.el = el; this.opts = opts; this.cases = []; this.out = null; this.pointer = { x: 0, y: 0, in: false }
    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true })
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
    this.renderer.shadowMap.enabled = true; this.renderer.shadowMap.type = THREE.PCFSoftShadowMap
    this.renderer.outputColorSpace = THREE.SRGBColorSpace; this.renderer.toneMapping = THREE.ACESFilmicToneMapping
    el.appendChild(this.renderer.domElement)
    this.scene = new THREE.Scene()
    this.camera = new THREE.PerspectiveCamera(opts.fov || 32, 1, 0.1, 200)
    this.scene.add(new THREE.HemisphereLight(0xcfd6ff, 0x1a1410, 0.6))
    const key = new THREE.DirectionalLight(0xfff1de, 2.2); key.position.set(-4, 8, 6); key.castShadow = true
    key.shadow.mapSize.set(1024, 1024); key.shadow.bias = -0.0004; key.shadow.normalBias = 0.02
    Object.assign(key.shadow.camera, { left: -10, right: 10, top: 8, bottom: -4, near: 1, far: 30 })
    this.key = key; this.scene.add(key, key.target)
    const rim = new THREE.DirectionalLight(0x8fb4ff, 0.6); rim.position.set(6, 3, -5); this.scene.add(rim)
    this.tint = new THREE.PointLight(0xffffff, 0, 12, 1.6); this.scene.add(this.tint)
    if (opts.floor !== false) {
      const floor = new THREE.Mesh(new THREE.PlaneGeometry(60, 60), new THREE.ShadowMaterial({ opacity: 0.45 }))
      floor.rotation.x = -Math.PI / 2; floor.position.y = opts.floorY ?? 0; floor.receiveShadow = true; this.scene.add(floor)
    }
    this.camPos = new THREE.Vector3(0, 2, 10); this.camLook = new THREE.Vector3(0, 1, 0); this.tPos = new THREE.Vector3(); this.tLook = new THREE.Vector3()
    this.detail = opts.detail || Object.assign(document.createElement("div"), { className: "detail" })
    if (!opts.detail) el.appendChild(this.detail)
    this.visible = true
    new IntersectionObserver(([e]) => { this.visible = e.isIntersecting }).observe(el)
    new ResizeObserver(() => this.resize()).observe(el); this.resize()
    this.bindInput()
    stages.push(this)
  }
  resize() {
    const w = this.el.clientWidth, h = this.el.clientHeight; if (!w || !h) return
    this.renderer.setSize(w, h, false); this.camera.aspect = w / h; this.camera.updateProjectionMatrix()
  }
  add(c) { motion(c); c.stage = this; this.scene.add(c.g); this.cases.push(c); return c }
  pick(e) {
    const r = this.renderer.domElement.getBoundingClientRect()
    const p = new THREE.Vector2(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1)
    const ray = new THREE.Raycaster(); ray.setFromCamera(p, this.camera)
    const hit = ray.intersectObjects(this.cases.filter((c) => c.g.visible).map((c) => c.g), true)[0]
    return hit ? this.cases.find((c) => c.idx === hit.object.userData.idx) : null
  }
  bindInput() {
    const cv = this.renderer.domElement
    let down = null, dragged = false
    cv.addEventListener("pointerdown", (e) => { down = { x: e.clientX, y: e.clientY, moved: 0 } })
    cv.addEventListener("pointermove", (e) => {
      const r = cv.getBoundingClientRect(); this.pointer = { x: ((e.clientX - r.left) / r.width) * 2 - 1, y: ((e.clientY - r.top) / r.height) * 2 - 1, in: true }
      if (down) { const dx = e.clientX - down.x; down.moved = Math.max(down.moved, Math.abs(dx)); this.opts.drag?.call(this, e.movementX || 0, dx) }
      if (e.pointerType === "mouse" && (!down || down.moved < 6)) this.hover(this.pick(e))
    })
    cv.addEventListener("pointerup", () => { dragged = !!(down && down.moved > 6); down = null })
    cv.addEventListener("pointerleave", () => { this.pointer.in = false; this.hover(null) })
    cv.addEventListener("click", (e) => { if (dragged) { dragged = false; return } this.click(this.pick(e)) })
    cv.addEventListener("wheel", (e) => { if (this.opts.wheel) { this.opts.wheel.call(this, e); } }, { passive: true })
  }
  hover(c) { for (const x of this.cases) x.thover = 0; if (c && c !== this.out) c.thover = 1; this.renderer.domElement.style.cursor = c ? "pointer" : "" }
  click(c) {
    if (this.opts.click && this.opts.click.call(this, c) === false) return
    if (c) OPEN(c.item, this.opts.label)
  }
  takeOut(c) {
    this.putBack(true)
    // A slim case is swapped for a full one, which then opens.
    if (c.slim) { this.outOf = c; c.g.visible = false; const f = this.add(fullCase(c.item, 100000 + c.idx)); f.pos.copy(c.pos); f.rot.copy(c.rot); c = f }
    this.out = c; c.thover = 0
    discArt(c); setTimeout(() => { if (this.out === c) c.tlid = -1.95 }, 420)
    const show = () => { if (c.pal) { this.tintTo = toColor(c.pal.light); this.el.style.backgroundColor = c.pal.ground; this.opts.onTint?.(c.pal) } }
    c.pal ? show() : picture(c.item.poster).then((p) => { if (p) { c.pal = p.pal; show() } })
    const it = c.item, href = it.type === "movie" || it.type === "tv" ? `/title/${it.type}/${it.id}` : null
    this.detail.innerHTML = `<div class="mono" style="opacity:.7">[ ${esc(this.opts.label || "on the shelf")} ]</div><h3>${esc(it.title)}</h3>
      <div class="meta mono">${it.year ? `<span>${esc(it.year)}</span>` : ""}${it.score ? `<span>★ ${it.score}</span>` : ""}${it.at ? `<span>${new Date(it.at * 1000).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" })}</span>` : ""}</div>
      ${href ? `<a href="${href}">Open on Roki →</a>` : ""}`
    this.detail.classList.add("on")
  }
  putBack(quiet) {
    if (this.out) {
      const c = this.out; c.tlid = 0
      if (this.outOf) { const slim = this.outOf; setTimeout(() => { this.scene.remove(c.g); this.cases = this.cases.filter((x) => x !== c); slim.g.visible = true }, 450); c.tpos.copy(slim.tpos); c.trot.copy(slim.trot); this.outOf = null }
      this.out = null
    }
    if (!quiet) { this.tintTo = null; this.el.style.backgroundColor = ""; this.detail.classList.remove("on"); this.opts.onTint?.(null) }
  }
  // Where a case taken out stands: in front of the camera, left of the card, turned so the lid opens away.
  outPose(dist = 6) {
    const dir = new THREE.Vector3().subVectors(this.tLook, this.tPos).normalize()
    const right = new THREE.Vector3().crossVectors(dir, new THREE.Vector3(0, 1, 0)).normalize()
    const wide = this.el.clientWidth > 700
    const p = this.tPos.clone().addScaledVector(dir, dist).addScaledVector(right, wide ? -1.0 : 0)
    if (!wide) p.y += 0.45
    this.out.tpos.copy(p); this.out.trot.set(-Math.asin(dir.y) * 0.5, Math.atan2(-dir.x, -dir.z) + 0.62, 0)
  }
  frame(t, dt) {
    if (!this.visible) return
    this.opts.place.call(this, t)
    // The first frame it is seen: everything where it belongs at once (cases began below the floor,
    // and a stage off screen does not move them, so they rose into view as it was scrolled to).
    if (!this.placed) { this.placed = true; this.camPos.copy(this.tPos); this.camLook.copy(this.tLook); for (const c of this.cases) { c.pos.copy(c.tpos); c.rot.copy(c.trot) } }
    if (this.out) this.outPose(this.opts.outDist)
    for (const c of this.cases) step(c, dt)
    const dx = this.pointer.in ? this.pointer.x * 0.35 : 0, dy = this.pointer.in ? -this.pointer.y * 0.18 : 0
    this.camPos.lerp(new THREE.Vector3(this.tPos.x + dx, this.tPos.y + dy, this.tPos.z), 1 - Math.exp(-dt * 5))
    this.camLook.lerp(this.tLook, 1 - Math.exp(-dt * 5))
    this.camera.position.copy(this.camPos); this.camera.lookAt(this.camLook)
    this.key.target.position.copy(this.camLook); this.key.position.set(this.camLook.x - 4, this.camLook.y + 8, 6)
    this.tint.intensity += ((this.tintTo ? 8 : 0) - this.tint.intensity) * (1 - Math.exp(-dt * 3))
    if (this.tintTo) this.tint.color.lerp(this.tintTo, 1 - Math.exp(-dt * 3))
    if (this.out) this.tint.position.set(this.out.pos.x + 1.4, this.out.pos.y + 1.4, this.out.pos.z + 2.2)
    this.renderer.render(this.scene, this.camera)
  }
}
// Fit a camera so `width` world units across (and `height` up) fill the stage.
function fit(stage, width, height) {
  const v = THREE.MathUtils.degToRad(stage.camera.fov), a = stage.camera.aspect
  const byH = height / 2 / Math.tan(v / 2), byW = width / 2 / (Math.tan(v / 2) * a)
  return Math.max(byH, byW)
}


function carousel(el, items, label = "recently watched", mode = "ring", wide = false) {
  let ring = 0, ringV = 0, slide = 0, slideV = 0
  const n = items.length
  const rows = mode === "two" ? [items.filter((_, i) => i % 2 === 0), items.filter((_, i) => i % 2 === 1)] : [items]
  const ringOf = (cnt) => ({stepA: Math.PI * 2 / cnt, R: cnt * (W + 0.3) / (Math.PI * 2)})
  // Inside: as tight as the cases allow, so they stand side by side round you.
  const bigR = Math.max(3.2, n * (W + 0.12) / (Math.PI * 2))
  const st = new Stage(el, {
    label, floorY: 0, outDist: 5.2,
    place() {
      if (mode === "arc") {
        // Cases at even steps along a gentle curve; `slide` moves them along it, settling on one.
        slide += slideV; slideV *= 0.9
        if (Math.abs(slideV) < 0.002 && !this.pointer.in) slide += (Math.round(slide) - slide) * 0.08
        if (!this.pointer.in && !this.out) slideV += 0.0006
        const gap = W + 0.25
        const viewW = 2 * this.tPos.z * Math.tan(THREE.MathUtils.degToRad(this.camera.fov) / 2) * this.camera.aspect
        this.cases.forEach((c, i) => {
          if (c === this.out) return
          let k = i - slide; k = ((k % n) + n * 1.5) % n - n / 2          // wraps round, centred
          const x = k * gap, z = -Math.pow(Math.abs(k), 1.6) * 0.18 + c.hover * 0.5
          c.tpos.set(x, H / 2 + 0.04, z); c.trot.set(0, -Math.sign(k) * Math.min(0.9, Math.abs(k) * 0.16), 0)
          c.g.visible = Math.abs(x) < viewW / 2 + gap * 1.5
        })
        this.tPos.set(0, 1.4, fit(this, Math.min(n * (W + 0.25), 15), H + 0.8)); this.tLook.set(0, 1.0, -0.6)
        return
      }
      // It turns by itself at a steady pace (by time, not per frame), pausing only while a case
      // is hovered or the ring is being dragged, and for a moment after; a drag's fling coasts.
      const now = performance.now(), dtR = Math.min(0.05, (now - (this.lastT || now)) / 1000); this.lastT = now
      const held = this.cases.some((c) => c.thover > 0) || this.dragging || now - (this.touched || 0) < 1500
      ring += ringV; ringV *= Math.pow(0.92, dtR * 60)
      if (!held && !this.out) ring += 0.16 * dtR
      if (mode === "inside") {
        // A big ring with the camera at its middle: the cases face in, round you.
        const stepA = Math.PI * 2 / n
        this.cases.forEach((c, i) => {
          if (c === this.out) return
          const a = i * stepA + ring, r = bigR - 0.5 * c.hover
          c.tpos.set(Math.sin(a) * r, H / 2 + 0.04, -Math.cos(a) * r); c.trot.set(0, -a, 0)
          c.g.visible = Math.cos(a) > -0.2
        })
        // Standing back toward the far side, so a wide sweep of the ring is in front.
        this.tPos.set(0, 1.2, bigR * 0.55); this.tLook.set(0, 1.0, -bigR)
        return
      }
      let idx = 0
      rows.forEach((row, ri) => {
        const {stepA, R} = ringOf(row.length), dir = ri === 0 ? 1 : -1, y = mode === "two" ? (ri === 0 ? H + 0.35 : 0) : 0
        row.forEach((_, j) => {
          const c = this.cases[idx++]
          if (c === this.out) return
          const a = j * stepA + ring * dir + (ri ? stepA / 2 : 0), r = R + 0.4 * c.hover
          c.tpos.set(Math.sin(a) * r, H / 2 + 0.04 + y, Math.cos(a) * r - R); c.trot.set(0, a, 0)
        })
      })
      const R = ringOf(rows[0].length).R
      const tall = mode === "two" ? 2 * H + 1.0 : H + 0.7
      // `wide`: framed to the whole ring, so a big one runs edge to edge.
      const span = wide ? 2 * R + W : Math.min(9, 2 * R + W * 0.6)
      this.tPos.set(0, mode === "two" ? 2.4 : wide ? 2.2 : 1.45, fit(this, span, tall) * (wide ? 0.62 : 0.8) + 0.3); this.tLook.set(0, mode === "two" ? 2.0 : 1.0, wide ? -R * 0.55 : -Math.min(1, R * 0.35))
      // A narrow stage (a phone's column): looked at a little lower, so the ring sits at the top
      // of its box instead of floating in the middle of empty space.
      if (!wide && mode === "ring" && this.el.clientWidth < 700) this.tLook.y -= 0.3
    },
    drag(mx) { this.touched = performance.now(); if (mode === "arc") slideV = -mx * 0.02; else ringV = mx * (mode === "inside" ? -0.0015 : 0.0025) },
    wheel(e) { if (!e.deltaX) return; this.touched = performance.now(); if (mode === "arc") slideV += e.deltaX * 0.002; else ringV += e.deltaX * -0.0003 },
  })
  const order = mode === "two" ? [...rows[0], ...rows[1]] : items
  order.forEach((it, i) => {
    const c = st.add(fullCase(it, i))
    if (it.extra) dress(c).then(() => { c.cover.material.color?.setScalar(0.45); if (c.spine.material.color) c.spine.material.color.setScalar(0.5) })
  })
  return st
}


function viewer3d(vstage) {
  const r = new THREE.WebGLRenderer({ antialias: true, alpha: true })
  r.setPixelRatio(Math.min(devicePixelRatio, 2)); r.outputColorSpace = THREE.SRGBColorSpace; r.toneMapping = THREE.ACESFilmicToneMapping
  vstage.appendChild(r.domElement)
  const scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(30, 1, 0.1, 100)
  camera.position.set(0, 0, 6.4); camera.lookAt(0, 0, 0)
  scene.add(new THREE.HemisphereLight(0xcfd6ff, 0x1a1410, 0.7))
  const key = new THREE.DirectionalLight(0xfff1de, 2.4); key.position.set(-3, 4, 6); scene.add(key)
  const rim = new THREE.DirectionalLight(0x8fb4ff, 0.8); rim.position.set(4, 2, -4); scene.add(rim)
  const tint = new THREE.PointLight(0xffffff, 0, 14, 1.4); tint.position.set(2.5, 2, 4); scene.add(tint)
  const st = { r, scene, camera, tint, c: null, yaw: 0, yawT: 0, drag: null, t: 0, raf: 0 }
  const size = () => { const w = vstage.clientWidth, h = vstage.clientHeight; if (!w || !h) return; r.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix() }
  new ResizeObserver(size).observe(vstage); size()
  // Only the case itself can be held and turned; anywhere else is "away", which closes.
  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2()
  st.onCase = (e) => {
    if (!st.c) return false
    const b = r.domElement.getBoundingClientRect()
    ndc.set((e.clientX - b.left) / b.width * 2 - 1, -(e.clientY - b.top) / b.height * 2 + 1)
    ray.setFromCamera(ndc, camera)
    return ray.intersectObject(st.c.g, true).length > 0
  }
  r.domElement.addEventListener("pointerdown", (e) => { if (st.onCase(e)) { st.drag = { x: e.clientX, yaw: st.yawT, moved: 0 }; r.domElement.setPointerCapture(e.pointerId) } })
  r.domElement.addEventListener("pointermove", (e) => {
    if (st.drag) { st.drag.moved += Math.abs(e.movementX); st.yawT = st.drag.yaw + (e.clientX - st.drag.x) * 0.008 }
    r.domElement.style.cursor = st.drag ? "grabbing" : st.onCase(e) ? "grab" : "default"
  })
  r.domElement.addEventListener("pointerup", () => { st.wasDrag = !!(st.drag && st.drag.moved > 4); st.drag = null })
  st.loop = (now) => {
    const dt = Math.min(0.033, (now - (st.last || now)) / 1000); st.last = now; st.t += dt
    if (st.c) {
      const c = st.c
      // Facing you, a little turned so the open lid shows; a slow sway when left alone.
      const sway = st.drag ? 0 : Math.sin(st.t * 0.6) * 0.1
      // Closed it stands in the middle; open, it moves right by half a case so the open pair (lid
      // left, disc right) is centred.
      const open = Math.min(1, -c.lid / 2.5)
      c.tpos.set(open * W * 0.5, 0.02 + Math.sin(st.t * 1.1) * 0.03, 0); c.trot.set(0.03, 0.12 + st.yawT + sway, 0)
      step(c, dt)
    }
    tint.intensity += ((st.c ? 7 : 0) - tint.intensity) * (1 - Math.exp(-dt * 3))
    r.render(scene, camera)
    st.raf = requestAnimationFrame(st.loop)
  }
  return st
}

async function globe(el) {
  el.innerHTML = ""
  const [topo, svg] = await Promise.all([
    fetch("/data/countries-110m.json").then((r) => r.json()),
    fetch("/data/world-110m.svg").then((r) => r.text()),
  ])
  // Countries by name → the site's codes (its map was made from the same atlas).
  const code = {}; for (const [, c, name] of svg.matchAll(/data-c="([A-Z]{2})"[^>]*><title>([^<]*)</g)) code[name] = c
  const feats = feature(topo, topo.objects.countries).features
  const TW = 2048, TH = 1024
  const proj = d3.geoEquirectangular().scale(TW / (2 * Math.PI)).translate([TW / 2, TH / 2])
  const tex = document.createElement("canvas"); tex.width = TW; tex.height = TH
  const tg = tex.getContext("2d"), path = d3.geoPath(proj, tg)
  tg.fillStyle = "#0b0a12"; tg.fillRect(0, 0, TW, TH)
  const ids = document.createElement("canvas"); ids.width = TW; ids.height = TH
  const ig = ids.getContext("2d", { willReadFrequently: true }), ipath = d3.geoPath(proj, ig)
  feats.forEach((f, i) => {
    const c = code[f.properties.name], n = c ? C.counts[c] || 0 : 0
    tg.beginPath(); path(f); tg.fillStyle = n ? `rgb(255,${Math.round(150 - 70 * heat(n))},40)` : "#2b2836"
    tg.globalAlpha = n ? 0.45 + 0.55 * heat(n) : 1; tg.fill(); tg.globalAlpha = 1
    tg.strokeStyle = "rgba(255,255,255,.18)"; tg.lineWidth = 1; tg.stroke()
    ig.beginPath(); ipath(f); ig.fillStyle = `rgb(${(i + 1) & 255},${(i + 1) >> 8},0)`; ig.fill()
  })
  const idpx = ig.getImageData(0, 0, TW, TH).data
  const r = new THREE.WebGLRenderer({ antialias: true, alpha: true })
  r.setPixelRatio(Math.min(devicePixelRatio, 2)); r.outputColorSpace = THREE.SRGBColorSpace
  el.appendChild(r.domElement)
  const scene = new THREE.Scene(), cam = new THREE.PerspectiveCamera(30, 1, 0.1, 50); cam.position.set(0, 0.35, 4.2); cam.lookAt(0, 0, 0)
  const map = new THREE.CanvasTexture(tex); map.colorSpace = THREE.SRGBColorSpace; map.anisotropy = 8
  const ball = new THREE.Mesh(new THREE.SphereGeometry(1, 96, 64), new THREE.MeshStandardMaterial({ map, emissiveMap: map, emissive: 0xffffff, emissiveIntensity: 0.35, roughness: 0.85 }))
  scene.add(ball)
  // A soft rim of light round it.
  const halo = new THREE.Mesh(new THREE.SphereGeometry(1.08, 64, 48), new THREE.ShaderMaterial({
    transparent: true, side: THREE.BackSide, depthWrite: false, blending: THREE.AdditiveBlending,
    vertexShader: "varying vec3 n; void main(){ n = normalize(normalMatrix * normal); gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }",
    fragmentShader: "varying vec3 n; void main(){ float i = pow(0.75 - dot(n, vec3(0,0,1.0)), 3.0); gl_FragColor = vec4(1.0,0.55,0.25,1.0) * i; }",
  }))
  scene.add(halo)
  scene.add(new THREE.HemisphereLight(0xdfe6ff, 0x221a14, 0.9))
  const sun = new THREE.DirectionalLight(0xffffff, 1.4); sun.position.set(-3, 2, 4); scene.add(sun)
  const tip = Object.assign(document.createElement("div"), { className: "maptip", hidden: true }); el.appendChild(tip)
  // Start looking at the country most was watched from.
  let yaw = -Math.PI / 2, pitch = 0.35, vy = 0, drag = null, hover = null, idle = 0
  const fit = () => { const w = el.clientWidth, h = el.clientHeight; if (w && h) { r.setSize(w, h, false); cam.aspect = w / h; cam.updateProjectionMatrix() } }
  new ResizeObserver(fit).observe(el); fit()
  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2()
  const pickAt = (e) => {
    const b = r.domElement.getBoundingClientRect(); ndc.set((e.clientX - b.left) / b.width * 2 - 1, -(e.clientY - b.top) / b.height * 2 + 1)
    ray.setFromCamera(ndc, cam); const hit = ray.intersectObject(ball)[0]; if (!hit) return null
    const u = hit.uv.x, v = hit.uv.y, k = (Math.floor((1 - v) * TH) * TW + Math.floor(u * TW)) * 4, i = idpx[k] + idpx[k + 1] * 256 - 1
    const f = i >= 0 ? feats[i] : null, c = f && code[f.properties.name]
    return f ? { name: f.properties.name, c, n: c ? C.counts[c] || 0 : 0 } : null
  }
  r.domElement.addEventListener("pointerdown", (e) => { drag = { x: e.clientX, y: e.clientY, yaw, pitch, moved: 0 } })
  addEventListener("pointerup", () => { setTimeout(() => { drag = null }, 0) })
  r.domElement.addEventListener("pointermove", (e) => {
    if (drag && e.buttons) { drag.moved += Math.abs(e.movementX) + Math.abs(e.movementY); yaw = drag.yaw + (e.clientX - drag.x) * 0.008; pitch = Math.max(-1.1, Math.min(1.1, drag.pitch + (e.clientY - drag.y) * 0.006)); idle = 0 }
    hover = pickAt(e); const b = r.domElement.getBoundingClientRect()
    tip.hidden = !hover; if (hover) { tip.innerHTML = `${esc(hover.name)} <b>${hover.n}</b>`; tip.style.left = `${e.clientX - b.left}px`; tip.style.top = `${e.clientY - b.top}px` }
    r.domElement.style.cursor = drag && e.buttons ? "grabbing" : hover?.n ? "pointer" : "grab"
  })
  r.domElement.addEventListener("pointerleave", () => { hover = null; tip.hidden = true })
  r.domElement.addEventListener("click", () => { if (hover?.n && hover.c && !(drag && drag.moved > 6)) location.href = watchedIn(hover.c) })
  const st = { visible: true, frame(t, dt) {
    idle += dt
    if (!hover && !(drag && drag.moved) && idle > 0.5) yaw += dt * 0.12
    ball.rotation.set(pitch, yaw, 0, "XYZ"); r.render(scene, cam)
  } }
  new IntersectionObserver(([e]) => { st.visible = e.isIntersecting }).observe(el)
  const f0 = st.frame; st.frame = (t, dt) => { if (st.visible) f0(t, dt) }
  stages.push(st)
}


function caseStacks(el) {
  const MAXH = 24, GAP = 1.75
  const piles = []
  let kind = "all", fan = []
  const flat = new THREE.BoxGeometry(W * 0.92, D * 0.9, H * 0.92)
  const labels = Object.assign(document.createElement("div"), { className: "slabels" }); el.appendChild(labels)
  const st = new Stage(el, {
    label: "ratings", floorY: 0, fov: 28, outDist: 6,
    click(c) { if (!c && this.fanOf) { location.href = atRating(this.fanOf.score, kind); return false } },
    place() {
      // Which pile is under the pointer (the fan above counts as its pile).
      const P = this.pointer
      let hot = null
      if (P.in) {
        const ray = new THREE.Raycaster(); ray.setFromCamera(new THREE.Vector2(P.x, -P.y), this.camera)
        const hit = ray.intersectObjects(piles.flatMap((p) => p.meshes))[0]
        hot = hit ? piles.find((p) => p.meshes.includes(hit.object)) : null
        if (!hot && this.cases.some((c) => c.thover > 0)) hot = this.fanOf
      }
      if (hot !== this.fanOf) setFan(hot)
      if (hot) this.renderer.domElement.style.cursor = "pointer"
      piles.forEach((p) => {
        const lift = p === hot ? 0.18 : 0
        p.meshes.forEach((m, j) => { m.position.y += ((j + 0.5) * D * 0.95 + lift - m.position.y) * 0.25 })
      })
      // The fan: up to five titles standing over the pile, spread like a hand.
      fan.forEach((c, k) => {
        const n = fan.length, a = (k - (n - 1) / 2) * 0.22
        const base = this.fanOf ? this.fanOf.x : 0, top = this.fanOf ? this.fanOf.meshes.length * D * 0.95 : 0
        // In front of the piles and a little above the tallest, so it is never cut by the frame.
        const x = Math.max(-6, Math.min(6, base))
        c.tpos.set(x + Math.sin(a) * 2.4, 2.6 + Math.cos(a) * 0.5 + 0.3 * c.hover, 3.2 + k * 0.03); c.trot.set(-0.2, 0, -a)
      })
      const span = piles.length * GAP
      this.tPos.set(0, 6.5, fit(this, span + 1.5, 7) * 0.95); this.tLook.set(0, 1.6, 0)
      // The numbers: the count over each pile, the score under it.
      for (const p of piles) {
        const top = new THREE.Vector3(p.x, p.meshes.length * D * 0.95 + 0.4, 0).project(this.camera)
        const bot = new THREE.Vector3(p.x, 0, H * 0.6).project(this.camera)
        const w = el.clientWidth, h = el.clientHeight
        p.n.style.transform = `translate(${(top.x + 1) / 2 * w}px, ${(1 - top.y) / 2 * h - 18}px)`
        p.s.style.transform = `translate(${(bot.x + 1) / 2 * w}px, ${(1 - bot.y) / 2 * h + 4}px)`
        p.n.style.opacity = p === hot || !hot ? 1 : 0.35
      }
    },
  })
  const titlesAt = (score) => data.history.filter((h) => h.score && Math.floor(h.score) === score && (kind === "all" || h.type === kind)).slice(0, 5)
  function setFan(p) {
    for (const c of fan) { st.scene.remove(c.g); st.cases = st.cases.filter((x) => x !== c) }
    fan = []; st.fanOf = p
    if (!p) return
    fan = titlesAt(p.score).map((it, k) => { const c = st.add(fullCase(it, 500 + k)); c.pos.set(p.x, 0.2, 0); c.rot.set(-1.4, 0, 0); return c })
  }
  function build() {
    for (const p of piles) { for (const m of p.meshes) st.scene.remove(m); p.n.remove(); p.s.remove() }
    piles.length = 0; setFan(null)
    const b = R[kind]; if (!b) return
    // Whole scores: a half score goes with the score below it.
    const by = new Map(); for (const x of b.bars) { const k = Math.max(1, Math.floor(x.score)); by.set(k, (by.get(k) || 0) + x.n) }
    const max = Math.max(1, ...by.values())
    for (let sc = 1; sc <= 10; sc++) {
      const n = by.get(sc) || 0, count = n ? Math.max(1, Math.round(n / max * MAXH)) : 0
      const color = (b.bars.find((x) => Math.floor(x.score) === sc && Number.isInteger(x.score)) || {}).color || "#888"
      const col = sc === 10 ? new THREE.Color(0xf4c430) : toColor(color)
      const x = (sc - 5.5) * GAP
      const top = titlesAt(sc)[0]
      const meshes = []
      for (let j = 0; j < count; j++) {
        const mats = new THREE.MeshStandardMaterial({ color: col.clone().multiplyScalar(0.55 + 0.25 * ((j * 7) % 3) / 2), roughness: 0.4, metalness: sc === 10 ? 0.5 : 0.05 })
        const m = new THREE.Mesh(flat, mats); m.position.set(x + ((j * 37) % 5 - 2) * 0.02, 0, ((j * 53) % 5 - 2) * 0.02); m.rotation.y = ((j * 29) % 7 - 3) * 0.02
        m.castShadow = m.receiveShadow = true; st.scene.add(m); meshes.push(m)
      }
      // The pile's top case wears the poster of a title at that score.
      if (meshes.length && top) picture(top.poster).then((pp) => {
        if (!pp) return
        const t = pp.tex.clone(); t.needsUpdate = true; t.center.set(0.5, 0.5); t.rotation = Math.PI
        const m = meshes.at(-1), mats = Array(6).fill(m.material); mats[2] = new THREE.MeshStandardMaterial({ map: t, roughness: 0.5 }); m.material = mats
      })
      const nEl = Object.assign(document.createElement("span"), { className: "sn", textContent: n || "" })
      const sEl = Object.assign(document.createElement("span"), { className: "ss", textContent: sc })
      labels.append(nEl, sEl)
      piles.push({ score: sc, x, meshes, n: nEl, s: sEl })
    }
  }
  build()
  return { setKind(k) { kind = k; build() } }
}


// ── the page: mount into the hook's element, unmount on the way out ─────────────────────────
let running = false, raf = 0, last = 0
function loop(now) {
  const dt = Math.min(0.033, (now - last) / 1000); last = now
  for (const s of stages) s.frame(now / 1000, dt)
  raf = requestAnimationFrame(loop)
}

// `root`: the hook's element (its data attributes, its `[data-stage]` slots, the map and ratings
// cards); `opts.open(item, label)` opens a title. Returns `{ destroy, setKind }`.
export function mount(root, opts) {
  destroy()
  OPEN = opts.open
  const J = (k, d) => { try { return JSON.parse(root.dataset[k] || "") } catch { return d } }
  const favs = J("favorites", {}), recent = J("recent", [])
  P = { name: root.dataset.name || "" }
  R = J("ratings", {})
  const counts = J("countries", {})
  C = { counts, names: {} }; cmax = Math.max(1, ...Object.values(counts))
  // The piles fan out titles at a score from what the page knows: the recently watched and the
  // favourites, each with the score this person gave.
  data = { ratings: R, history: [...recent, ...Object.values(favs).flat()].filter((h) => h.score && h.poster) }
  const labels = { movie: "Favorite Movies", tv: "Favorite Shows", anime: "Favorite Anime", manga: "Favorite Manga" }
  for (const el of root.querySelectorAll("[data-stage]")) {
    const k = el.dataset.stage
    if (k === "recent") { if (recent.length) carousel(el, recent, "recently watched", "ring", true) }
    else if ((favs[k] || []).length) carousel(el, favs[k], (el.closest("section")?.querySelector("h2")?.textContent || labels[k] || "").trim().toLowerCase())
  }
  const mapEl = root.querySelector("[data-globe]")
  if (mapEl && Object.keys(counts).length) globe(mapEl).catch((e) => console.warn("globe", e))
  const pileEl = root.querySelector("[data-piles]")
  let piles = null
  if (pileEl && R.all) piles = caseStacks(pileEl)
  if (!running) { running = true; last = performance.now(); raf = requestAnimationFrame(loop) }
  return { destroy, setKind: (k) => piles?.setKind(k) }
}

export function destroy() {
  cancelAnimationFrame(raf); running = false
  for (const s of stages) {
    try { s.renderer?.dispose(); s.renderer?.forceContextLoss?.(); s.renderer?.domElement?.remove(); s.el?.querySelector?.(".detail")?.remove() } catch {}
    s.dispose?.()
  }
  stages = []
}

// The opened view's case (or book): into `el`, turning to face you and opening. `{ destroy }`.
export function viewerCase(el, it) {
  const V = viewer3d(el)
  const c = motion(fullCase(it, 0)); V.scene.add(c.g)
  c.pos.set(0.4, -2.6, -1.5); c.rot.set(0.3, -1.6, 0.1); V.yawT = 0; V.c = c
  discArt(c); const t = setTimeout(() => { if (V.c === c) c.tlid = c.book ? -2.75 : -2.55 }, 1300)
  picture(it.poster).then((p) => {
    if (!p || V.c !== c) return
    V.tint.color.copy(toColor(p.pal.light))
    if (c.book) return
    const lidIn = c.hinge.children.find((m) => m.material === inner)
    if (lidIn) { const tx = p.tex.clone(); tx.needsUpdate = true; lidIn.material = new THREE.MeshStandardMaterial({ map: tx, roughness: 0.6, color: 0xbbbbbb }) }
  })
  V.last = 0; V.raf = requestAnimationFrame(V.loop)
  return {
    onCase: (e) => V.onCase(e),
    wasDrag: () => { const w = V.wasDrag; V.wasDrag = false; return w },
    destroy() { clearTimeout(t); cancelAnimationFrame(V.raf); V.r.dispose(); V.r.forceContextLoss?.(); V.r.domElement.remove() },
  }
}
