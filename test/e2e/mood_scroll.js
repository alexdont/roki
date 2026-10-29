// The featured page's mood picker. Two things it must never do:
//
//   1. On a phone, move the page when the carousel turns by itself (every six seconds).
//   2. Change the size of a chip when it is lit, which pushes every chip after it along.
//   3. Open a mood's page when a chip is tapped on a touch screen. A tap is the only way to look
//      there, so it shows the mood in the carousel; the "Show me" button inside the slide opens
//      the page. With a mouse it is the other way about: hover to look, click to open.
//
// The first, in detail:
//
// It used to. The lit chip was kept in view with `scrollIntoView`, which scrolls every ancestor
// that can scroll, the page included, so anyone reading further down was carried back up to the
// picker each time a mood turned (and again whenever the page updated).
//
// Needs no login — the featured page is public. Run it inside the container, against the
// running server:
//
//   docker exec roki-ee bash -lc 'cd /www/app && NODE_PATH=/usr/lib/node_modules node test/e2e/mood_scroll.js'
//
// BASE overrides the address. Exits 0 when everything holds.
const {chromium} = require("playwright")

const BASE = process.env.BASE || "http://localhost:4000"

;(async () => {
  const browser = await chromium.launch({args: ["--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu", "--single-process", "--no-zygote"]})
  const ctx = await browser.newContext({viewport: {width: 390, height: 780}, hasTouch: true, isMobile: true})
  const page = await ctx.newPage()
  const results = []
  const check = (name, pass, extra = "") => {
    results.push(pass)
    console.log(`${pass ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`)
  }

  await page.goto(`${BASE}/home`, {waitUntil: "networkidle"})
  await page.waitForSelector("[data-mood-chip]")
  const lit = () => page.evaluate(() => document.querySelector('[data-mood-chip][aria-selected="true"]')?.dataset.moodChip)
  const y = () => page.evaluate(() => Math.round(window.scrollY))

  // 1. Reading further down, with nothing touched: let the carousel turn on its own.
  await page.evaluate(() => window.scrollTo(0, 900))
  await page.waitForTimeout(300)
  const start = await y()
  const first = await lit()
  let drift = 0
  for (let i = 0; i < 14; i++) {
    await page.waitForTimeout(1000)
    drift = Math.max(drift, Math.abs((await y()) - start))
  }
  const turned = await lit()
  check("the carousel turned, so the test means something", turned !== first, `${first} -> ${turned}`)
  check("and the page did not move while it did", drift < 2, `largest drift ${drift}px`)

  // 2. Much further down, where the old code carried you the whole way back up.
  await page.evaluate(() => window.scrollTo(0, 3500))
  await page.waitForTimeout(300)
  const far = await y()
  await page.evaluate(() => document.querySelectorAll("[data-mood-chip]")[1].dispatchEvent(new Event("mouseenter")))
  await page.waitForTimeout(8000)
  check("from 3,500px down, turning the mood does not move the page", (await y()) === far, `${far} -> ${await y()}`)

  // 3. What `scrollIntoView` was there for must still work: the row follows the lit mood sideways.
  await page.evaluate(() => window.scrollTo(0, 0))
  await page.waitForTimeout(300)
  const geometry = () => page.evaluate(() => {
    const chip = document.querySelector('[data-mood-chip][aria-selected="true"]')
    const row = chip.parentElement
    const c = chip.getBoundingClientRect(), r = row.getBoundingClientRect()
    return {scroll: Math.round(row.scrollLeft), centre: Math.round(c.left + c.width / 2), rowCentre: Math.round(r.left + r.width / 2)}
  })
  const before = await geometry()
  await page.evaluate(() => {
    const chips = document.querySelectorAll("[data-mood-chip]")
    chips[chips.length - 2].dispatchEvent(new Event("mouseenter"))
  })
  await page.waitForTimeout(1000)
  const after = await geometry()
  check("the chip row scrolls sideways to the lit mood", after.scroll > before.scroll, `row at ${before.scroll} -> ${after.scroll}`)
  check("and the lit chip ends up in the middle of the row", Math.abs(after.centre - after.rowCentre) <= 24, `chip ${after.centre}, row ${after.rowCentre}`)

  await browser.close()

  // 4. No chip changes size when it is lit, on a desktop (where the chips wrap onto lines, so a
  //    chip that grew would also re-wrap everything after it) and on a phone (where they scroll).
  //    Layout positions (offset*), so a transition in flight cannot make it pass.
  for (const [label, viewport, touch] of [["desktop", {width: 1280, height: 800}, false], ["phone", {width: 390, height: 780}, true]]) {
    const b = await chromium.launch({args: ["--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu", "--single-process", "--no-zygote"]})
    const p = await (await b.newContext({viewport, hasTouch: touch, isMobile: touch, reducedMotion: "reduce"})).newPage()
    await p.goto(`${BASE}/home`, {waitUntil: "networkidle"})
    await p.waitForSelector("[data-mood-chip]")
    await p.waitForTimeout(600)
    const layout = () => p.evaluate(() => [...document.querySelectorAll("[data-mood-chip]")].map((c) => ({slug: c.dataset.moodChip, x: c.offsetLeft, y: c.offsetTop, w: c.offsetWidth, h: c.offsetHeight})))
    const rest = await layout()
    const first = rest[0].slug // lit at rest, so its own size is the lit one
    const changed = []
    for (const {slug} of rest) {
      await p.evaluate((s) => document.querySelector(`[data-mood-chip="${s}"]`).dispatchEvent(new Event("mouseenter")), slug)
      await p.waitForTimeout(450)
      for (const c of await layout()) {
        const was = rest.find((r) => r.slug === c.slug)
        if (c.w !== was.w || c.h !== was.h || (c.slug !== first && (c.x !== was.x || c.y !== was.y))) changed.push(`${c.slug} while ${slug} was lit`)
      }
    }
    await b.close()
    check(`${label}: no chip changes size or moves, whichever is lit`, changed.length === 0, changed.length ? `${changed.length} changes, e.g. ${changed.slice(0, 3).join("; ")}` : `${rest.length} chips, ${rest.length} states`)
  }

  // 5. A touch screen: a tap shows the mood and does not leave the page.
  {
    const b = await chromium.launch({args: ["--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu", "--single-process", "--no-zygote"]})
    const p = await (await b.newContext({viewport: {width: 390, height: 780}, hasTouch: true, isMobile: true})).newPage()
    await p.goto(`${BASE}/home`, {waitUntil: "networkidle"})
    await p.waitForSelector("[data-mood-chip]")
    const lit = () => p.evaluate(() => document.querySelector('[data-mood-chip][aria-selected="true"]')?.dataset.moodChip)
    const slide = () => p.evaluate(() => [...document.querySelectorAll("[data-mood]")].find((s) => !s.classList.contains("opacity-0"))?.dataset.mood)
    const path = () => new URL(p.url()).pathname

    const order = await p.evaluate(() => [...document.querySelectorAll("[data-mood-chip]")].map((c) => c.dataset.moodChip))
    const taps = [order[2], order[5], order[3]]
    let stayed = true, switched = true
    for (const slug of taps) {
      await p.tap(`[data-mood-chip="${slug}"]`)
      await p.waitForTimeout(700)
      if (path() !== "/home") stayed = false
      if ((await lit()) !== slug || (await slide()) !== slug) switched = false
    }
    check("phone: tapping chips one after another stays on the page", stayed, `at ${path()}`)
    check("phone: and each tap shows that mood, chip and slide together", switched, `last: ${await lit()} / ${await slide()}`)

    // The turning must not be left held by the tap: it goes on from the mood chosen.
    const chosen = taps[taps.length - 1]
    await p.waitForTimeout(7000)
    const next = order[(order.indexOf(chosen) + 1) % order.length]
    check("phone: the carousel keeps turning after a tap, from the mood chosen", (await lit()) === next, `${chosen} -> ${await lit()} (expected ${next})`)

    await p.locator(`[data-mood="${await lit()}"] a`, {hasText: "Show me"}).tap()
    await p.waitForURL(/\/mood\//, {timeout: 8000}).catch(() => {})
    check("phone: the Show me button inside the slide opens the mood's page", path().startsWith("/mood/"), path())
    await b.close()
  }

  // 6. A mouse: hovering shows the mood, and clicking opens its page.
  {
    const b = await chromium.launch({args: ["--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu", "--single-process", "--no-zygote"]})
    const p = await (await b.newContext({viewport: {width: 1280, height: 800}})).newPage()
    await p.goto(`${BASE}/home`, {waitUntil: "networkidle"})
    await p.waitForSelector("[data-mood-chip]")
    await p.hover('[data-mood-chip="thrill"]')
    await p.waitForTimeout(700)
    const litNow = await p.evaluate(() => document.querySelector('[data-mood-chip][aria-selected="true"]')?.dataset.moodChip)
    check("desktop: hovering a chip shows that mood without leaving the page", litNow === "thrill" && new URL(p.url()).pathname === "/home")
    await p.click('[data-mood-chip="thrill"]')
    await p.waitForURL(/\/mood\/thrill/, {timeout: 8000}).catch(() => {})
    check("desktop: clicking a chip opens that mood's page", new URL(p.url()).pathname === "/mood/thrill", new URL(p.url()).pathname)
    await b.close()
  }

  const failed = results.filter((r) => !r).length
  console.log(failed ? `\n${failed} FAILED` : "\nall passed")
  process.exit(failed ? 1 : 0)
})().catch((e) => {
  console.error("script failed:", e.message)
  process.exit(2)
})
