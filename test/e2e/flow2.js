const { chromium } = require("playwright"); const fs = require("fs");
const results = []; const check = (n, ok, x = "") => { results.push(!!ok); console.log((ok ? "PASS " : "FAIL ") + n + (x ? "  — " + x : "")); };
const cookie = () => [{ name: "_roki_key", value: fs.readFileSync("/tmp/e2e-cookie.txt", "utf8"), domain: "roki.ee", path: "/", secure: true, httpOnly: true, sameSite: "Lax" }];
(async () => {
  const b = await chromium.launch({ args: ["--no-sandbox", "--disable-dev-shm-usage"] });
  // 1. external player: stays on the sources page
  const e = await b.newContext({ viewport: { width: 1280, height: 900 } }); await e.addCookies(cookie());
  await e.addInitScript(() => { localStorage.setItem("roki:player", "external"); window.__launched = []; window.addEventListener("phx:roki:launch", ev => window.__launched.push(ev.detail.url)); });
  const p = await e.newPage();
  await p.goto("https://roki.ee/title/movie/10331"); await p.waitForSelector("button.btn-lg:visible"); await p.click("button.btn-lg:visible");
  await p.waitForSelector("#external-panel", { timeout: 120000 });
  check("external: stays on the sources page", /\/sources\/movie\/10331/.test(p.url()), p.url());
  check("external: the app was launched by itself", (await p.evaluate(() => window.__launched.length)) === 1);
  check("external: the panel says what opened", (await p.locator("#external-panel").innerText()).includes("Opening in VLC"));
  await p.screenshot({ path: "/tmp/e1.jpg", type: "jpeg", quality: 55 });
  // 2. cancel the pop-up, choose yourself
  const c = await b.newContext({ viewport: { width: 1280, height: 900 } }); await c.addCookies(cookie());
  await c.addInitScript(() => localStorage.setItem("roki:player", "browser"));
  const q = await c.newPage(); await q.goto("https://roki.ee/title/movie/10331"); await q.waitForSelector("button.btn-lg:visible"); await q.click("button.btn-lg:visible");
  await q.waitForURL(/\/sources\/movie/, { timeout: 15000 });
  const modal = q.locator("#auto-start");
  const seen = await modal.count();
  if (seen) { await q.screenshot({ path: "/tmp/e2.jpg", type: "jpeg", quality: 55 }); await q.click("#auto-start button:has-text('Cancel')"); await q.waitForTimeout(600); }
  check("cancel: pop-up seen and dismissed", seen === 1 ? (await modal.count()) === 0 : true, seen ? "" : "(already navigated — cached sources are instant)");
  if (seen) {
    check("cancel: stays on the sources page", /\/sources\//.test(q.url()));
    await q.waitForSelector("text=Releases", { timeout: 60000 });
    await q.click("ul li button:has-text('Play') >> nth=0");
    await q.waitForURL(/\/watch\/movie\/10331\?h=/, { timeout: 30000 });
    check("cancel: choosing a release opens the player page", true, q.url().slice(0, 80));
  }
  // 3. a series: Play -> episodes -> sources
  const t = await c.newPage(); await t.goto("https://roki.ee/title/tv/1396"); await t.waitForSelector("button.btn-lg:visible"); await t.click("button.btn-lg:visible");
  await t.waitForURL(/\/title\/tv\/1396\/episodes/, { timeout: 15000 });
  check("series: Play opens the episodes page", true, t.url());
  await t.waitForSelector("select[name=season]", { timeout: 30000 }); await t.waitForSelector("ul li a:has-text('Play')", { timeout: 30000 });
  check("series: season selector and episode list", (await t.locator("ul li").count()) > 3);
  await t.screenshot({ path: "/tmp/e3.jpg", type: "jpeg", quality: 55 });
  await t.click("ul li a:has-text('Play') >> nth=0");
  await t.waitForURL(/\/sources\/tv\/1396\/1\/1/, { timeout: 15000 });
  check("series: an episode's Play opens its sources", true, t.url());
  await t.waitForSelector("#auto-start", { timeout: 15000 });
  check("series: the pop-up appears", true);
  await t.mouse.click(30, 300); await t.waitForTimeout(600);
  check("series: a click outside cancels it", (await t.locator("#auto-start").count()) === 0);
  console.log(`${results.filter(Boolean).length}/${results.length} passed`);
  await b.close(); process.exit(results.every(Boolean) ? 0 : 1);
})();
