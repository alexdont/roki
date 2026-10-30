// Manual e2e: the title page's hero trailer on a wide screen — it starts by itself, muted, and pauses,
// resumes, turns the sound on and off and goes full screen on the viewer's say; it stops by itself
// when scrolled out of sight and goes on only if the viewer had not paused it. Needs a session
// cookie (COOKIE, default /tmp/e2e-cookie.txt) and a title that has a trailer (U); run inside the
// container with NODE_PATH=/usr/lib/node_modules.
const {chromium} = require("playwright"); const fs = require("fs")
;(async () => {
  const b = await chromium.launch({args: ["--no-sandbox","--single-process","--no-zygote","--disable-dev-shm-usage","--autoplay-policy=no-user-gesture-required"]})
  const c = await b.newContext({viewport: {width: 1440, height: 900}})
  await c.addCookies([{name: "_roki_key", value: fs.readFileSync(process.env.COOKIE || "/tmp/e2e-cookie.txt","utf8").trim(), domain: "roki.ee", path: "/", secure: true, httpOnly: true, sameSite: "Lax"}])
  const p = await c.newPage(); const errs = []
  p.on("pageerror", e => errs.push(String(e).slice(0,200)))
  const flags = () => p.evaluate(() => { const h = document.querySelector("#hero"); return {playing: h.dataset.heroPlaying, live: h.dataset.heroLive, muted: h.dataset.heroMuted, ended: h.dataset.heroEnded, fs: !!document.fullscreenElement, iframe: document.querySelectorAll("#hero-video iframe").length} })
  await p.goto((process.env.U || "https://roki.ee/title/movie/1507696"), {waitUntil: "load"})
  await p.waitForSelector("#hero", {state: "attached", timeout: 20000})
  console.log("hero is up (nothing playing yet):", JSON.stringify(await flags()))
  await p.waitForTimeout(8000)
  console.log("autoplayed, muted:", JSON.stringify(await flags()))
  await p.locator('[data-hero-ctl="play"]').click(); await p.waitForTimeout(1500)
  console.log("after pause click:", JSON.stringify(await flags()))
  await p.waitForTimeout(2500)
  console.log("3s later it is still paused (no restart):", JSON.stringify(await flags()))
  await p.locator('[data-hero-ctl="play"]').click(); await p.waitForTimeout(1500)
  console.log("after play click:", JSON.stringify(await flags()))
  await p.locator('[data-hero-ctl="mute"]').click(); await p.waitForTimeout(500)
  console.log("after sound-on click:", JSON.stringify(await flags()))
  await p.screenshot({path: "/root/shots/hero-unmuted.png", clip: {x: 900, y: 580, width: 540, height: 140}})
  await p.locator('[data-hero-ctl="mute"]').click(); await p.waitForTimeout(500)
  console.log("after sound-off click:", JSON.stringify(await flags()))
  // scroll away: it should pause by itself, and come back when scrolled back
  await p.evaluate(() => window.scrollTo(0, 1600)); await p.waitForTimeout(2500)
  console.log("scrolled away:", JSON.stringify(await flags()))
  await p.evaluate(() => window.scrollTo(0, 0)); await p.waitForTimeout(2500)
  console.log("scrolled back:", JSON.stringify(await flags()))
  // a viewer's pause stays a pause across scrolling
  await p.locator('[data-hero-ctl="play"]').click(); await p.waitForTimeout(1200)
  await p.evaluate(() => window.scrollTo(0, 1600)); await p.waitForTimeout(1500)
  await p.evaluate(() => window.scrollTo(0, 0)); await p.waitForTimeout(2500)
  console.log("paused by viewer, scrolled away and back (must stay paused):", JSON.stringify(await flags()))
  // full screen
  await p.locator('[data-hero-ctl="full"]').click(); await p.waitForTimeout(1200)
  console.log("after full-screen click:", JSON.stringify(await flags()))
  await p.keyboard.press("Escape"); await p.waitForTimeout(600)
  console.log("errors:", errs)
  await b.close()
})()
