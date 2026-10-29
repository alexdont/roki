// The rating dialog's slider, in a real browser, with the real stylesheet and the real slider code.
//
// The scale used to run red, yellow, green, and then back round to yellow for the top scores, so 8
// looked worse than 7 and 10 looked like a yellow 4. It is one ramp now — red, yellow, green, and
// then deepening toward emerald, never turning back — and ten is the one score that is gold: a
// metal, drawn as a gradient on the number and the thumb and as a hard-edged notch at the end of
// the track. `RokiWeb.ScoreColor` says what colour each score is; this checks that the slider
// draws it.
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
const hue = (colour) => {
  const m = /rgb\((\d+), (\d+), (\d+)\)/.exec(colour || "")
  if (!m) return null
  const [r, g, b] = [m[1], m[2], m[3]].map((n) => Number(n) / 255)
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min
  if (d === 0) return 0
  const h = (max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4) * 60
  return Math.round(h < 0 ? h + 360 : h)
}

;(async () => {
  const results = []
  const check = (name, pass, extra = "") => {
    results.push(pass)
    console.log(`${pass ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`)
  }
  const browser = await chromium.launch({args: ["--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu", "--single-process", "--no-zygote"]})
  const page = await (await browser.newContext({viewport: {width: 420, height: 520}})).newPage()

  const open = async (name, {script = true} = {}) => {
    const html = fs.readFileSync(path.join(dir, `${name}.html`), "utf8").replace(/ hidden items-end/, " flex items-end")
    await page.setContent(`<!doctype html><html data-theme="light"><head><meta charset="utf-8"><style>${css}</style></head><body class="bg-base-100">${html}${script ? `<script>${code}</script>` : ""}</body></html>`, {waitUntil: "load"})
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
      word: word.textContent, thumb: i.style.getPropertyValue("--thumb"), dataGold: i.hasAttribute("data-gold"), fill: getComputedStyle(out).backgroundImage,
    }
  })

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
  check("the thumb is gold, not a colour from the ramp", ten.dataGold && ten.thumb === "")

  // 3. and coming back down puts it all back
  await set(9)
  const back = await state()
  check("back on 9 it is green again and the gold is gone", !back.gold && !back.wordGold && !back.dataGold && hue(back.color) > 140, back.color)
  await set(10)
  await set(4)
  const four = await state()
  check("from gold straight down to 4 it is a colour again, with nothing left of the gold", !four.gold && !four.dataGold && four.color !== "" && four.thumb !== "")

  // 4. the words go with the scores
  await set(10)
  check("10 has its word", (await state()).word === "masterpiece", (await state()).word)

  // 5. opened on 10, it is gold before any script has run
  await open("gold", {script: false})
  const first = await page.evaluate(() => ({
    gold: document.getElementById("rate-out").classList.contains("rate-gold"),
    inline: document.getElementById("rate-out").getAttribute("style"),
    data: document.querySelector(".rate-range").hasAttribute("data-gold"),
  }))
  check("a dialog opened on 10 is gold on its first paint", first.gold && first.data && !first.inline, JSON.stringify(first))

  // 6. the track: smooth to 9.5, then a hard gold notch — on both kinds of slider
  for (const name of ["tmdb", "mal"]) {
    await open(name)
    const track = await page.evaluate(() => document.querySelector(".rate-range").getAttribute("style"))
    const stops = track.slice(track.indexOf("linear-gradient")).replace(/\);?\s*$/, "").split(/,(?![^()]*\))/).map((x) => x.trim())
    const gold = stops.filter((x) => x.startsWith("var(--gold)"))
    const lastGreen = stops[stops.length - 3]
    const edge = (x) => x.split(" ").pop().replace(/\)$/, "")
    check(`${name}: the track ends in a gold notch with a hard edge`, gold.length === 2 && edge(gold[0]) === edge(lastGreen) && edge(gold[1]) === "100%", `${lastGreen} | ${gold.join(" | ")}`)
  }

  await browser.close()
  fs.rmSync(dir, {recursive: true, force: true})
  const failed = results.filter((r) => !r).length
  console.log(failed ? `\n${failed} FAILED` : "\nall passed")
  process.exit(failed ? 1 : 0)
})().catch((e) => {
  console.error("script failed:", e.message)
  process.exit(2)
})
