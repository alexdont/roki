const { chromium } = require("playwright");
// End-to-end check of the study sidebar in a real browser (Playwright is in the dev
// image): `ROKI_URL=http://localhost:4000 NODE_PATH=$(npm root -g) node test/e2e/study.js`.
const BASE = process.env.ROKI_URL || "http://localhost:4000";
const results = [];
const check = (name, ok, extra = "") => { results.push(!!ok); console.log((ok ? "PASS " : "FAIL ") + name + (extra ? "  — " + extra : "")); };
const toS = x => { const m = /(\d+):(\d+):(\d+)\.(\d+)/.exec(x); return +m[1] * 3600 + +m[2] * 60 + +m[3] + +m[4] / 1000 };

(async () => {
  const b = await chromium.launch({ args: ["--no-sandbox", "--autoplay-policy=no-user-gesture-required"] });
  const ctx = await b.newContext({ viewport: { width: 1280, height: 900 } });
  const p = await ctx.newPage();
  const errors = [];
  p.on("pageerror", e => errors.push(String(e)));
  p.on("console", m => { if (m.type() === "error" && !/favicon|ERR_FAILED|404/.test(m.text())) errors.push(m.text()); });

  await p.goto(BASE + "/study", { waitUntil: "domcontentloaded" });
  await p.waitForSelector("[data-phx-main].phx-connected", { timeout: 20000 });

  // the demo loads, nothing highlighted yet
  await p.click("[data-role=demo]");
  await p.waitForSelector(".study-row", { timeout: 10000 });
  const n = await p.locator(".study-row").count();
  const vtt = await p.evaluate(async () => await (await fetch("/study/demo.vtt")).text());
  const cueList = [...vtt.matchAll(/(\d+:\d+:\d+\.\d+) --> (\d+:\d+:\d+\.\d+)/g)].map(m => ({ a: toS(m[1]), b: toS(m[2]) })).sort((x, y) => x.a - y.a);
  check("one row per cue", n === cueList.length && n > 20, `${n} rows, ${cueList.length} cues`);
  check("title and counter", (await p.textContent("[data-role=title]")).includes("Demo") && (await p.textContent("[data-role=count]")).trim() === `0 / ${n}`);
  check("empty message gone", await p.locator("[data-role=empty]").isHidden());
  await p.waitForFunction(() => document.getElementById("study-video").readyState >= 1);

  const state = () => p.evaluate(() => {
    const rows = [...document.querySelectorAll(".study-row")];
    return { live: rows.filter(r => r.dataset.live).map(r => +r.dataset.idx), current: rows.findIndex(r => r.dataset.state === "current"),
             past: rows.filter(r => r.dataset.state === "past").length, count: document.querySelector("[data-role=count]").textContent.trim() };
  });
  const seek = async t => { await p.evaluate(t => { const v = document.getElementById("study-video"); v.pause(); v.currentTime = t }, t); await p.waitForTimeout(250); };

  // what is current, live and past at known moments
  await seek(2);    let s = await state();
  check("t=2.0 first line is live and current", JSON.stringify(s.live) === "[0]" && s.current === 0 && s.past === 0, JSON.stringify(s));
  await seek(3.5);  s = await state();
  check("t=3.5 in a gap: line 0 is current, nothing is live", s.live.length === 0 && s.current === 0, JSON.stringify(s));
  await seek(5);    s = await state();
  check("t=5.0 second line live, first is past", JSON.stringify(s.live) === "[1]" && s.past === 1 && s.count === `2 / ${n}`, JSON.stringify(s));
  await seek(51.5); s = await state();
  check("t=51.5 two overlapping lines both live", s.live.length === 2, JSON.stringify(s));
  await seek(0.2);  s = await state();
  check("before the first line: nothing current, nothing past", s.current === -1 && s.live.length === 0 && s.past === 0 && s.count === `0 / ${n}`, JSON.stringify(s));

  // seeking centres the current line in the list, and never scrolls the page
  await p.evaluate(() => window.scrollTo(0, 0));
  await seek(40);
  const c = await p.evaluate(() => {
    const list = document.querySelector("[data-role=list]"), row = document.querySelector(".study-row[data-state=current]");
    const lr = list.getBoundingClientRect(), rr = row.getBoundingClientRect();
    return { off: Math.round((rr.top + rr.height / 2) - (lr.top + lr.height / 2)), scrollTop: Math.round(list.scrollTop), page: window.scrollY };
  });
  check("seek to 40s: current row centred in the list", Math.abs(c.off) <= 12 && c.scrollTop > 0, JSON.stringify(c));
  check("the page itself did not scroll", c.page === 0);

  // near the end the list runs out of room: it stops at the bottom rather than overshooting
  await seek(72);
  const end = await p.evaluate(() => { const l = document.querySelector("[data-role=list]"); return { gap: Math.round(l.scrollHeight - l.clientHeight - l.scrollTop) } });
  check("near the end the list rests at the bottom", Math.abs(end.gap) <= 2, JSON.stringify(end));
  // and highlighting never changes the list's size — that would make it jump under you
  const sizes = [];
  for (const tt of [2, 6, 12, 20, 33, 51.5, 60, 72]) { await seek(tt); sizes.push(await p.evaluate(() => document.querySelector("[data-role=list]").scrollHeight)); }
  check("the list height is the same whichever line is lit", new Set(sizes).size === 1, JSON.stringify([...new Set(sizes)]));

  // playing at 8x: the lit row always matches the video clock
  await seek(0);
  await p.evaluate(() => { const v = document.getElementById("study-video"); v.playbackRate = 8; return v.play() });
  const samples = [];
  for (let i = 0; i < 14; i++) {
    samples.push(await p.evaluate(() => {
      const v = document.getElementById("study-video"), t = v.currentTime;
      const cur = document.querySelector(".study-row[data-state=current]");
      return { t, cur: cur ? +cur.dataset.idx : -1 };
    }));
    await p.waitForTimeout(450);
  }
  let bad = 0, checked = 0; const moved = new Set();
  for (const smp of samples) {
    if (smp.t > 74) continue;
    let exp = -1; cueList.forEach((cu, i) => { if (cu.a <= smp.t) exp = i });
    checked++; moved.add(smp.cur);
    if (Math.abs(smp.cur - exp) > 1) bad++;   // one line of slack for the instant between sampling and drawing
  }
  check("playing: highlighted line tracks the clock", bad === 0 && checked >= 8, `${checked} samples, ${bad} off`);
  check("playing: it advanced through many lines", moved.size >= 8, `${moved.size} different lines`);

  // scroll it yourself: it stops following, offers a way back, and resumes
  await p.evaluate(() => { const v = document.getElementById("study-video"); v.currentTime = 5; v.playbackRate = 1; v.play() });
  await p.waitForTimeout(600);
  await p.hover(".study-row >> nth=10");
  await p.mouse.wheel(0, 700);
  await p.waitForTimeout(300);
  const top1 = await p.evaluate(() => document.querySelector("[data-role=list]").scrollTop);
  check("manual scroll shows the way back", await p.locator("[data-role=resume]").isVisible());
  await p.evaluate(() => { document.getElementById("study-video").currentTime = 20 });
  await p.waitForTimeout(900);
  const top2 = await p.evaluate(() => document.querySelector("[data-role=list]").scrollTop);
  check("while you scroll, the list is not yanked back", Math.abs(top2 - top1) < 4, `${top1} -> ${top2}`);
  await p.click("[data-role=resume]");
  await p.waitForTimeout(1100);
  const back = await p.evaluate(() => { const list = document.querySelector("[data-role=list]"), row = document.querySelector(".study-row[data-state=current]"); const lr = list.getBoundingClientRect(), rr = row.getBoundingClientRect(); return Math.round((rr.top + rr.height / 2) - (lr.top + lr.height / 2)) });
  check("the pill brings the current line back to the centre", Math.abs(back) <= 20 && await p.locator("[data-role=resume]").isHidden(), `off by ${back}px`);

  // click a line: plays from there
  await p.evaluate(() => document.getElementById("study-video").pause());
  await p.locator(".study-row").nth(8).scrollIntoViewIfNeeded();
  await p.locator(".study-row").nth(8).click();
  await p.waitForTimeout(500);
  const after = await p.evaluate(() => { const v = document.getElementById("study-video"); return { t: v.currentTime, paused: v.paused } });
  check("clicking a line plays from it", Math.abs(after.t - cueList[8].a) < 1.2 && !after.paused, `row 8 starts ${cueList[8].a}s, video at ${after.t.toFixed(1)}s, paused=${after.paused}`);

  // layout: the sidebar is exactly as tall as the video, to its right
  const h = await p.evaluate(() => ({ v: Math.round(document.getElementById("study-video").getBoundingClientRect().height), s: Math.round(document.querySelector("#study-sidebar > div").getBoundingClientRect().height),
                                      vx: Math.round(document.getElementById("study-video").getBoundingClientRect().right), sx: Math.round(document.querySelector("#study-sidebar").getBoundingClientRect().left) }));
  check("sidebar is as tall as the video, and to its right", Math.abs(h.v - h.s) <= 2 && h.sx > h.vx, JSON.stringify(h));
  await p.evaluate(() => window.scrollTo(0, 0));
  if (process.env.SHOT) await p.screenshot({ path: process.env.SHOT, type: "jpeg", quality: 60 });

  // upload a subtitle file (SRT in Latin-1, with accents and markup) through the real form
  const srt = Buffer.from("1\n00:00:01,000 --> 00:00:03,000\nÀ bientôt, lété <i>arrive</i>\n\n2\n00:00:04,000 --> 00:00:06,500\nDeuxième ligne\n", "latin1");
  await p.setInputFiles("#subtitles-form input[type=file]", { name: "episode.fr.srt", mimeType: "application/x-subrip", buffer: srt });
  await p.waitForFunction(() => document.querySelector("[data-role=title]").textContent.includes("episode.fr.srt"), null, { timeout: 15000 });
  const up = await p.evaluate(() => [...document.querySelectorAll(".study-text")].map(e => e.textContent));
  check("an uploaded .srt replaces the lines (accents and markup handled)", up.length === 2 && up[0] === "À bientôt, lété arrive" && up[1] === "Deuxième ligne", JSON.stringify(up));

  await p.setInputFiles("#subtitles-form input[type=file]", { name: "notes.txt", mimeType: "text/plain", buffer: Buffer.from("hello") });
  await p.waitForFunction(() => /not a subtitle file/.test(document.body.textContent), null, { timeout: 10000 });
  check("a non-subtitle file is refused with a message, lines unchanged", (await p.locator(".study-text").count()) === 2);

  check("no console or page errors", errors.length === 0, errors.join(" | ").slice(0, 300));
  console.log(`\n${results.filter(Boolean).length}/${results.length} passed`);
  await b.close();
  process.exit(results.every(Boolean) ? 0 : 1);
})();
