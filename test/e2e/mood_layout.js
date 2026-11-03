// Manual e2e: every mood slide of the home carousel at phone to desktop widths — the posters keep
// their 2:3 shape and nothing runs into the button, whatever the length of a title or a tagline.
// Needs a session cookie (COOKIE, default /tmp/e2e-cookie.txt); run inside the container with
// NODE_PATH=/usr/lib/node_modules. W=360,1280 picks widths; V=1 prints every slide.
const {chromium} = require("playwright"); const fs = require("fs")
const widths = (process.env.W || "360,390,430,640,768,1024,1280").split(",").map(Number)
;(async () => {
  for (const w of widths) {
    const b = await chromium.launch({args: ["--no-sandbox","--single-process","--no-zygote","--disable-dev-shm-usage"]})
    const c = await b.newContext({viewport: {width: w, height: 900}})
    await c.addCookies([{name: "_roki_key", value: fs.readFileSync(process.env.COOKIE || "/tmp/e2e-cookie.txt","utf8").trim(), domain: "roki.ee", path: "/", secure: true, httpOnly: true, sameSite: "Lax"}])
    const p = await c.newPage()
    await p.goto((process.env.BASE || "https://roki.ee") + "/", {waitUntil: "load"}); await p.waitForTimeout(6000)
    const rows = await p.evaluate(() => {
      const out = []
      for (const s of document.querySelectorAll("#mood-picker [data-mood]")) {
        const box = s.parentElement.getBoundingClientRect()
        const h1 = s.querySelector("h1").getBoundingClientRect()
        const tag = s.querySelector("p.text-base, p.sm\\:text-lg") || s.querySelectorAll("p")[1]
        const btn = [...s.querySelectorAll("a")].find(a => /Show me/.test(a.innerText))
        const bt = btn && btn.getBoundingClientRect()
        const posters = [...s.querySelectorAll("a[title]")].map(a => a.getBoundingClientRect())
        const p0 = posters[0]
        out.push({m: s.dataset.mood, box: Math.round(box.height), h1: Math.round(h1.height), tagH: Math.round(tag.getBoundingClientRect().height), btnH: bt ? Math.round(bt.height) : null, btnBottom: bt ? Math.round(bt.bottom - box.top) : null, posterW: p0 && Math.round(p0.width), posterH: p0 && Math.round(p0.height), ratio: p0 && +(p0.height / p0.width).toFixed(2), postersTop: p0 && Math.round(p0.top - box.top)})
      }
      return out
    })
    const bad = rows.filter(r => r.ratio && r.ratio < 1.45 || (r.posterW > 0 && r.btnBottom && r.postersTop && r.btnBottom > r.postersTop))
    const shapes = rows.filter(r => r.ratio > 0).map(r => r.ratio)
    console.log(`w=${w}: ${rows.length} slides, box=${rows[0].box}px, ` + (shapes.length ? `poster ratio min=${Math.min(...shapes)} (want 1.5)` : "poster strip hidden (wide screen)") + `, overlaps=${bad.length}`)
    if (process.env.V || bad.length) for (const r of (process.env.V ? rows : bad)) console.log("   ", JSON.stringify(r))
    await b.close()
  }
})()
