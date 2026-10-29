// The rating dialog's slider, in a real browser, with the real stylesheet and the real slider code.
//
// The bar is the colour of the score under the thumb, as on TMDB: filled up to the thumb and tinted
// beyond, so the whole bar changes as the thumb moves — red, through yellow, to green, and never
// turning back (it used to swing back to yellow, so 8 looked worse than 7). Ten is the one score
// that is gold, a metal rather than a hue: the whole bar is gold, and it glows.
// `RokiWeb.ScoreColor` says what colour each score is; this checks that the slider draws it.
//
// Needs no login and no server: it renders the dialog itself and loads it into a blank page.
// Run it inside the container:
//
//   docker exec roki-ee bash -lc 'cd /www/app && NODE_PATH=/usr/lib/node_modules node test/e2e/rating_slider.js'
//
// Exits 0 when everything holds.
const {chromium} = require("playwright")
const {execFileSync} = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

const ROOT = path.resolve(__dirname, "../..")
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rating-slider-"))
execFileSync("mix", ["run", "test/e2e/support/rating_sheet.exs", dir], {cwd: ROOT, env: {...process.env, PHX_SERVER: "false"}, stdio: "pipe"})

const css = fs.readFileSync(path.join(ROOT, "priv/static/assets/css/app.css"), "utf8")
// The real slider code, lifted out of the real source.
const src = fs.readFileSync(path.join(ROOT, "assets/js/app.js"), "utf8")
const code = src.slice(src.indexOf("let SCORE_WORDS = {}"), src.indexOf("// Play on an external player"))
if (!code.includes("window.rokiScore")) throw new Error("could not find the slider code in assets/js/app.js")

// The browser hands colours back as rgb(); the hue is what the scale is about.
const hueOf = ([r, g, b]) => {
  [r, g, b] = [r, g, b].map((n) => n / 255)
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min
  if (d === 0) return 0
  const h = (max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4) * 60
  return Math.round(h < 0 ? h + 360 : h)
}
const rgb = (css) => { const m = /rgb\((\d+), (\d+), (\d+)\)/.exec(css || ""); return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null }
const hue = (css) => (rgb(css) ? hueOf(rgb(css)) : null)
const dist = (a, b) => Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]) + Math.abs(a[2] - b[2])

;(async () => {
  const results = []
  const check = (name, pass, extra = "") => {
    results.push(pass)
    console.log(`${pass ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`)
  }
  const browser = await chromium.launch({args: ["--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu", "--single-process", "--no-zygote"]})
  const page = await (await browser.newContext({viewport: {width: 420, height: 520}, deviceScaleFactor: 1})).newPage()

  const open = async (name, {script = true} = {}) => {
    const html = fs.readFileSync(path.join(dir, `${name}.html`), "utf8").replace(/ hidden items-end/, " flex items-end")
    await page.setContent(`<!doctype html><html data-theme="light"><head><meta charset="utf-8"><style>${css}.rate-range{transition:none !important;animation:none !important}</style></head><body class="bg-base-100">${html}${script ? `<script>${code}</script>` : ""}</body></html>`, {waitUntil: "load"})
  }
  const set = (v) => page.evaluate((v) => {
    const i = document.querySelector(".rate-range")
    i.value = v
    i.dispatchEvent(new Event("input", {bubbles: true}))
  }, v)
  const state = () => page.evaluate(() => {
    const i = document.querySelector(".rate-range"), out = document.getElementById("rate-out"), word = document.getElementById("rate-word")
    return {
      text: out.textContent, color: out.style.color, gold: out.classList.contains("rate-gold"), wordGold: word.classList.contains("rate-gold"),
      word: word.textContent, c: i.style.getPropertyValue("--c"), p: i.style.getPropertyValue("--p"), dataGold: i.hasAttribute("data-gold"),
      fill: getComputedStyle(out).backgroundImage,
    }
  })

  // The bar as pixels: a row through its middle, with the thumb either hidden or left in.
  const row = async (hideThumb) => {
    await page.evaluate((hide) => document.querySelector(".rate-range").classList.toggle("no-thumb", hide), hideThumb)
    if (hideThumb) await page.addStyleTag({content: ".no-thumb::-webkit-slider-thumb{opacity:0 !important}.no-thumb::-moz-range-thumb{opacity:0 !important}"})
    const bar = page.locator(".rate-range")
    const box = await bar.boundingBox()
    const buf = await bar.screenshot()
    const out = await page.evaluate(async ({b64}) => {
      const img = await createImageBitmap(await (await fetch(`data:image/png;base64,${b64}`)).blob())
      const c = new OffscreenCanvas(img.width, img.height), g = c.getContext("2d")
      g.drawImage(img, 0, 0)
      const data = g.getImageData(0, Math.floor(img.height / 2), img.width, 1).data
      const px = []
      for (let x = 0; x < img.width; x++) px.push([data[x * 4], data[x * 4 + 1], data[x * 4 + 2], data[x * 4 + 3]])
      return {w: img.width, px}
    }, {b64: buf.toString("base64")})
    await page.evaluate(() => document.querySelector(".rate-range").classList.remove("no-thumb"))
    return {...out, width: box.width}
  }

  await open("tmdb")

  // 1. one ramp, one direction
  const hues = []
  for (let v = 1; v <= 9.5; v += 0.5) {
    await set(v)
    hues.push([v, hue((await state()).color)])
  }
  const all = hues.every(([, h]) => h !== null)
  check("every score from 1 to 9.5 has a colour to measure", all)
  check("the hue only ever rises: red, yellow, green, and then it stays green", all && hues.every(([, h], i) => i === 0 || h >= hues[i - 1][1] - 1), hues.filter(([v]) => [1, 3, 5, 7, 8, 9, 9.5].includes(v)).map(([v, h]) => `${v}:${h}°`).join(" "))
  check("past 7 nothing goes back toward yellow", all && hues.filter(([v]) => v >= 7).every(([, h]) => h >= 125))

  // 2. nine and a half is the last green; ten is something else
  await set(9.5)
  const nineHalf = await state()
  check("9.5 is a green, not gold", !nineHalf.gold && !nineHalf.dataGold && hue(nineHalf.color) > 140, nineHalf.color)
  await set(10)
  const ten = await state()
  check("10 is gold: the number and the word wear it and have no colour of their own", ten.gold && ten.wordGold && ten.color === "")
  check("the number is filled with the gold gradient", /linear-gradient/.test(ten.fill))
  check("the bar is marked gold and runs the whole way along", ten.dataGold && ten.c === "var(--gold)" && ten.p === "1", `--c ${ten.c}, --p ${ten.p}`)

  // 3. and coming back down puts it all back
  await set(9)
  const back = await state()
  check("back on 9 it is green again and the gold is gone", !back.gold && !back.wordGold && !back.dataGold && hue(back.color) > 140, back.color)
  await set(10)
  await set(4)
  const four = await state()
  check("from gold straight down to 4 it is a colour again, with nothing left of the gold", !four.gold && !four.dataGold && four.c !== "var(--gold)" && four.c !== "")

  // 4. the words go with the scores
  await set(10)
  check("10 has its word", (await state()).word === "masterpiece", (await state()).word)

  // 5. the fill ends under the middle of the thumb, on both kinds of slider
  for (const [kind, values] of [["tmdb", [2, 5, 7, 9.5]], ["mal", [3, 8]]]) {
    await open(kind)
    for (const v of values) {
      await set(v)
      const bare = await row(true)
      const fill = bare.px[Math.round(bare.width * 0.04)]
      let edge = bare.px.findIndex((p, x) => x > 4 && dist(p, fill) > 60)
      if (edge < 0) edge = bare.w
      // The thumb's ring is white, and nothing else inside the bar is.
      const withThumb = await row(false)
      const white = withThumb.px.map((p, x) => (p[0] > 245 && p[1] > 245 && p[2] > 245 && p[3] > 200 ? x : -1)).filter((x) => x >= 6 && x <= withThumb.w - 6)
      const centre = white.length ? (Math.min(...white) + Math.max(...white)) / 2 : null
      check(`${kind} at ${v}: the fill ends under the middle of the thumb`, centre !== null && Math.abs(edge - centre) <= 2.5, `fill ends at ${edge}px, thumb middle at ${centre}px`)
    }
  }

  // 6. the whole bar is the score's colour — the part beyond the thumb is a tint of it, not grey
  await open("tmdb")
  for (const v of [2, 7]) {
    await set(v)
    const bare = await row(true)
    const fill = bare.px[Math.round(bare.width * 0.04)]
    const beyond = bare.px[Math.round(bare.width * 0.95)]
    const lighter = beyond[0] + beyond[1] + beyond[2] > fill[0] + fill[1] + fill[2]
    check(`at ${v} the bar beyond the thumb is a tint of the same colour`, lighter && Math.abs(hueOf(fill) - hueOf(beyond)) <= 15, `fill hue ${hueOf(fill)}°, beyond ${hueOf(beyond)}°`)
  }

  // 7. ten: the whole bar is gold from end to end
  await set(10)
  const gold = await row(true)
  const sample = [0.06, 0.2, 0.4, 0.6, 0.8, 0.92].map((f) => gold.px[Math.round(gold.width * f)])
  // Gold is an amber hue that is not grey; the gradient runs from a deep gold to a pale highlight,
  // so what is checked is the hue and that it is a colour, not a fixed brightness.
  const goldish = (p) => hueOf(p) >= 38 && hueOf(p) <= 56 && Math.max(...p.slice(0, 3)) - Math.min(...p.slice(0, 3)) > 60
  check("at 10 the whole bar is gold, not just the part up to the thumb", sample.every(goldish), sample.map((p) => `${hueOf(p)}°`).join(" "))

  // 8. opened on 10, it is gold before any script has run
  await open("gold", {script: false})
  const first = await page.evaluate(() => ({
    gold: document.getElementById("rate-out").classList.contains("rate-gold"),
    inline: document.getElementById("rate-out").getAttribute("style"),
    data: document.querySelector(".rate-range").hasAttribute("data-gold"),
    p: document.querySelector(".rate-range").style.getPropertyValue("--p"),
  }))
  check("a dialog opened on 10 is gold on its first paint", first.gold && first.data && !first.inline && first.p === "1.0", JSON.stringify(first))

  await browser.close()
  fs.rmSync(dir, {recursive: true, force: true})
  const failed = results.filter((r) => !r).length
  console.log(failed ? `\n${failed} FAILED` : "\nall passed")
  process.exit(failed ? 1 : 0)
})().catch((e) => {
  console.error("script failed:", e.message)
  process.exit(2)
})
