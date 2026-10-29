// Panel overlay — debug layer for the upcoming panel-by-panel manga reader.
//
// Detects comic panels on each page of the paged reader (the fresco
// canvas `#fresco-reader`) and paints a colored shape over every one,
// numbered in reading order, so detection quality can be eyeballed on a
// real chapter before anything is built on top of it.
//
// Toggle: the "Panels" button in fresco's nav column (persisted in
// localStorage), or `?panels=1` in the URL. Off by default.
//
// Detection lives in panel_detect.js and runs in a Web Worker
// (panel_worker.js) so it never stalls swiping; the page's full-size
// pixels are posted over and the detector shrinks them itself.
//
// The SVG layer mirrors fresco's transform every frame (`update-viewport`)
// so shapes stay pinned through pan, zoom and rotation.
//
// Smart panels (reader setting, `<meta name="smart-panels">` from the
// root layout): Next / Prev step through a page's panels in reading
// order, each zoomed to fit and centred; past the last panel the page
// turns and lands on the next page's first panel (Prev lands on the
// previous page's last one). The paged reader asks through `window.__pagedPanelStep` /
// `__pagedPanelLanded` / `__pagedPanelTapOk`. Single-page mode only.

import { detectFromImage } from "./panel_detect";

const VIEWER_ID = "fresco-reader";
const STORAGE_KEY = "panelOverlay";
const SVG_NS = "http://www.w3.org/2000/svg";
const WORKER_URL = "/assets/js/panel_worker.js";
const BOOT_TIME = Date.now();

// Panel focus: breathing room around the panel (fraction of its long
// side), zoom cap (× the page's fit scale) so tiny panels don't blow
// up, glide length (a step within the page; a trip over to the next
// page runs longer, up to the max), how far a long trip pulls back
// mid-way, and how long a page turn waits on detection before falling
// back to showing the whole page.
const FOCUS_PAD = 0.03;
const FOCUS_MAX_ZOOM = 3;
const GLIDE_MS = 160;
const GLIDE_MAX_MS = 300;
const GLIDE_DIP = 0.2;
const HOLD_MS = 1500;
const COLORS = ["#ff3b6b", "#2bb3ff", "#ffb020", "#36d399", "#a78bfa", "#ff7a2b", "#22d3ee", "#f472b6"];

// ── Detection (off the main thread) ───────────────────────────────────

let worker = null, workerBroken = false, nextJob = 0;
const jobs = new Map();

function getWorker() {
  if (worker || workerBroken || typeof Worker === "undefined") return worker;
  try {
    // fresh URL per page load: the static plug sends no max-age, so a
    // browser can otherwise keep running an old detector next to new app.js
    worker = new Worker(`${WORKER_URL}?v=${BOOT_TIME}`);
    worker.onmessage = ({ data }) => {
      const job = jobs.get(data.id);
      if (!job) return;
      jobs.delete(data.id);
      data.error ? job.reject(new Error(data.error)) : job.resolve(data.result);
    };
    worker.onerror = () => {
      workerBroken = true; worker = null;
      for (const job of jobs.values()) job.retry();
      jobs.clear();
    };
  } catch (_) {
    workerBroken = true;
  }
  return worker;
}

/**
 * Detect panels on a loaded, same-origin <img>. Resolves to
 * `{ panels, bits, bgDark, ms }` with shapes in natural-image pixels:
 * each `{ x, y, w, h, area, hull: [[x, y], ...] }` (area = page fraction).
 */
export function detectPanels(img, direction = "rtl") {
  const t0 = performance.now();
  // full size: the detector shrinks it itself, identically everywhere
  const nw = img.naturalWidth, nh = img.naturalHeight;
  const cv = document.createElement("canvas");
  cv.width = nw; cv.height = nh;
  const ctx = cv.getContext("2d", { willReadFrequently: true });
  ctx.drawImage(img, 0, 0);
  const px = ctx.getImageData(0, 0, nw, nh).data;

  const local = () => {
    const res = detectFromImage(px, nw, nh, direction);
    return { ...res, ms: Math.round(performance.now() - t0) };
  };
  const w = getWorker();
  if (!w) return Promise.resolve().then(local);

  return new Promise((resolve, reject) => {
    const id = ++nextJob;
    jobs.set(id, {
      resolve: (res) => resolve({ ...res, ms: Math.round(performance.now() - t0) }),
      reject,
      retry: () => { try { resolve(local()); } catch (e) { reject(e); } }
    });
    w.postMessage({ id, px, nw, nh, direction }, [px.buffer]);
  });
}

// ── Overlay ────────────────────────────────────────────────────────────

function attach(handle) {
  if (typeof handle.getImages !== "function" || handle.__panelOverlay) return;
  handle.__panelOverlay = true;

  const results = new Map(); // src → detection result
  let enabled = readEnabled();
  let smart = readSmartPanels();
  // Panel-focus state: which page / panel the camera is on (idx -1 =
  // whole page), a focus waiting on detection, and the scale the camera
  // was last put at (a pinch away from it hands taps back to the reader).
  let focus = { page: currentPageFromUrl(), idx: -1 };
  let pending = null;
  let autoScale = 0, animUntil = 0;

  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("class", "panel-overlay");
  Object.assign(svg.style, {
    position: "absolute", inset: "0", width: "100%", height: "100%",
    overflow: "visible", pointerEvents: "none", zIndex: "40"
  });
  const root = document.createElementNS(SVG_NS, "g");
  const dbg = document.createElementNS(SVG_NS, "g");
  root.append(dbg);
  svg.appendChild(root);
  const container = handle.container;
  if (getComputedStyle(container).position === "static") container.style.position = "relative";
  container.appendChild(svg);

  // Project canvas px to the container with fresco's transform:
  //   screen − rect = (tx, ty) + R(rot) · s · p
  // done here per point rather than as an SVG transform, so the shapes
  // never carry the reader's ~30,000 px canvas coordinates.
  function syncTransform() {
    if (!enabled) return;
    const t = handle.getTransform();
    const rad = ((t.rotation || 0) * Math.PI) / 180;
    const c = Math.round(Math.cos(rad)), sn = Math.round(Math.sin(rad));
    const at = ([x, y]) => [t.tx + t.s * (c * x - sn * y), t.ty + t.s * (sn * x + c * y)];
    for (const el of dbg.children) {
      if (el.__pts) {
        el.setAttribute("points", el.__pts.map((p) => at(p).map((v) => v.toFixed(1)).join(",")).join(" "));
      } else if (el.__at) {
        const [x, y] = at(el.__at);
        el.setAttribute("transform", `translate(${x.toFixed(1)} ${y.toFixed(1)})`);
      }
    }
  }

  function render() {
    dbg.replaceChildren();
    dbg.style.display = enabled ? "" : "none";
    if (!enabled) { syncTransform(); return; }

    for (const im of handle.getImages()) {
      const res = results.get(im.src);
      if (!res || !im.naturalWidth) continue;
      // natural-image px → canvas px for this page
      const sx = im.width / im.naturalWidth, sy = im.height / im.naturalHeight;
      const tx = (x, y) => [im.x + x * sx, im.y + y * sy];

      res.bits.forEach((b) => {
        dbg.appendChild(poly(b.hull.map(([x, y]) => tx(x, y)), {
          fill: "none", stroke: "#9ca3af", "stroke-width": "1.5", "stroke-dasharray": "3 3"
        }));
      });

      // art escaping a panel over its neighbour: dashed, in the owner's color
      res.panels.forEach((p, i) => {
        const color = COLORS[i % COLORS.length];
        // sure = origin found (only this panel claims it); unsure ones are
        // claimed by both neighbours and drawn fainter, dotted
        (p.escapes || []).forEach((e) => {
          dbg.appendChild(poly(e.hull.map(([x, y]) => tx(x, y)), e.sure
            ? { fill: color, "fill-opacity": "0.12", stroke: color, "stroke-width": "2.5", "stroke-dasharray": "6 4" }
            : { fill: "none", stroke: color, "stroke-width": "1.5", "stroke-dasharray": "2 4", "stroke-opacity": "0.7" }));
        });
      });

      res.panels.forEach((p, i) => {
        const color = COLORS[i % COLORS.length];
        dbg.appendChild(poly(p.hull.map(([x, y]) => tx(x, y)), {
          fill: color, "fill-opacity": "0.22", stroke: color, "stroke-width": "2.5"
        }));
        const [lx, ly] = tx(p.x, p.y);
        dbg.appendChild(badge(i + 1, color, lx, ly));
      });
    }
    syncTransform();
  }

  // ── Smart panels: camera ───────────────────────────────────────────

  const pageImage = (page) => handle.getImages().find((i) => i.id === `page-${page}`);
  const pageResult = (page) => {
    const im = pageImage(page);
    const res = im && results.get(im.src);
    return res && im.naturalWidth ? { im, res } : null;
  };

  // Canvas-px bbox of panel `idx` on `page`: its hull plus every art /
  // balloon spill it may own. Unsure ones (claimed by both neighbours —
  // typically a balloon straddling the border) count too: showing a
  // bubble with both panels beats cutting its text off.
  function panelRect(im, p) {
    const sx = im.width / im.naturalWidth, sy = im.height / im.naturalHeight;
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    const add = (pts) => pts.forEach(([x, y]) => {
      x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y);
    });
    add(p.hull);
    (p.escapes || []).forEach((e) => add(e.hull));
    const pad = FOCUS_PAD * Math.max((x1 - x0) * sx, (y1 - y0) * sy);
    return {
      x: im.x + x0 * sx - pad, y: im.y + y0 * sy - pad,
      width: (x1 - x0) * sx + 2 * pad, height: (y1 - y0) * sy + 2 * pad
    };
  }

  function wholePage({ im, res }, idx) {
    const r = panelRect(im, res.panels[idx]);
    return r.width * r.height >= 0.85 * im.width * im.height;
  }

  function focusPanel(page, idx, animate = true, onDone) {
    const hit = pageResult(page);
    const p = hit?.res.panels[idx];
    if (!p) return false;
    const { im } = hit;
    focus = { page, idx };
    pending = null;

    const vp = container.getBoundingClientRect();
    const rot = handle.getTransform().rotation || 0;
    const sideways = rot === 90 || rot === 270;
    const fit = (w, h) => sideways
      ? Math.min(vp.width / h, vp.height / w)
      : Math.min(vp.width / w, vp.height / h);

    let rect = panelRect(im, p);
    let s = fit(rect.width, rect.height);
    const cap = fit(im.width, im.height) * FOCUS_MAX_ZOOM;
    if (s > cap) {
      // too small to blow up all the way: frame a bigger box, same centre
      const cx = rect.x + rect.width / 2, cy = rect.y + rect.height / 2;
      const w = (sideways ? vp.height : vp.width) / cap, h = (sideways ? vp.width : vp.height) / cap;
      rect = { x: cx - w / 2, y: cy - h / 2, width: w, height: h };
      s = cap;
    }

    // A panel about as big as the page (a splash, a title page) wants
    // less zoom than the page fit. fresco would clamp the zoom up to its
    // floor but keep the position worked out for the smaller zoom,
    // leaving the camera off in empty canvas, so frame it at the floor.
    const floor = handle.getZoomFloor?.() || 0;
    if (s < floor) s = floor;

    // The reader clamps pan to the page; a corner panel couldn't be
    // centred inside that. The page's own fit (next page turn, pinch
    // back out) restores the clamp.
    handle.setPanBounds?.(null);
    handle.setZoomCeiling?.(Math.max(s * 1.5, cap * 1.5));
    autoScale = s;
    // Frame the viewport-shaped box around the panel so every in-between
    // box (current view → target) fits at exactly its own scale.
    const vw = (sideways ? vp.height : vp.width) / s, vh = (sideways ? vp.width : vp.height) / s;
    const target = {
      x: rect.x + rect.width / 2 - vw / 2, y: rect.y + rect.height / 2 - vh / 2, width: vw, height: vh
    };
    glide(target, animate && !rot, onDone);
    return true;
  }

  // The canvas handle only has an instant fitBounds (its {animate} option
  // calls a controller.animateTo the canvas engine doesn't expose), so
  // glide by refitting an in-between box each frame. Centre and zoom
  // move together (zoom in log space, so it feels even); a long trip —
  // over to the next page — pulls back a little mid-way so it reads as
  // one continuous camera move.
  let glideId = 0;
  function glide(target, animate, onDone) {
    const id = ++glideId;
    const from = animate && handle.getViewportBounds?.();
    const finish = () => { if (id === glideId) onDone?.(); };
    if (!from || !(from.width > 0)) {
      handle.fitBounds(target);
      animUntil = 0;
      finish();
      return;
    }
    const fx = from.x + from.width / 2, fy = from.y + from.height / 2;
    const tx = target.x + target.width / 2, ty = target.y + target.height / 2;
    const aspect = target.height / target.width;
    const lw0 = Math.log(from.width), lw1 = Math.log(target.width);
    // travel in viewport widths (at the wider of the two views)
    const travel = Math.hypot(tx - fx, ty - fy) / Math.max(from.width, target.width);
    const dip = Math.min(GLIDE_DIP, travel * 0.12);
    const ms = Math.min(GLIDE_MAX_MS, GLIDE_MS + travel * 60);
    // never pull back past the page's zoom floor (fresco would clamp)
    const maxW = (container.clientWidth || 1) / Math.max(1e-6, handle.getZoomFloor?.() || 1e-6);
    animUntil = performance.now() + ms + 120;
    const t0 = performance.now();
    // ease-out: moving on the first frame, like the strip reader's snap —
    // a tap mid-glide restarts from here at full speed, never a slow start
    const ease = (t) => 1 - Math.pow(1 - t, 3);
    const frame = (now) => {
      if (id !== glideId) return;
      const t = Math.min(1, (now - t0) / ms);
      if (t >= 1) { handle.fitBounds(target); finish(); return; }
      const k = ease(t);
      const w = Math.min(maxW, Math.exp(lw0 + (lw1 - lw0) * k) * (1 + dip * Math.sin(Math.PI * k)));
      const h = w * aspect;
      const cx = fx + (tx - fx) * k, cy = fy + (ty - fy) * k;
      handle.fitBounds({ x: cx - w / 2, y: cy - h / 2, width: w, height: h });
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }

  function clearFocus(page) {
    glideId++;
    focus = { page, idx: -1 };
    if (pending) clearTimeout(pending.timer);
    pending = null;
  }

  // Land on the first (going forward) / last panel of a page we just
  // turned to. `held`: the reader left the camera to us (the page left
  // behind is still showing) — glide across, then let it tidy up.
  function landOn(page, dir, held, settle) {
    if (!smart) return false;
    const n = pageResult(page)?.res.panels.length || 0;
    if (!n) return false;
    focusPanel(page, dir > 0 ? 0 : n - 1, true, held ? settle : undefined);
    return true;
  }

  // A new chapter swapped in: there's no "previous view" on its canvas.
  // Start the camera one page over (blank canvas, on the side the
  // previous page would be), so the first panel slides in like any
  // other page turn.
  function offPageStart(page) {
    const im = pageImage(page);
    if (!im) return;
    const other = pageImage(page + 1);
    const side = other ? -Math.sign(other.x - im.x) || 1 : (window.__pagedDirection === "ltr" ? -1 : 1);
    const vp = container.getBoundingClientRect();
    const s = Math.min(vp.width / im.width, vp.height / im.height);
    const w = vp.width / s, h = vp.height / s;
    handle.setPanBounds?.(null);
    handle.fitBounds({
      x: im.x + im.width / 2 - w / 2 + side * im.width * 1.05, y: im.y + im.height / 2 - h / 2, width: w, height: h
    });
  }

  // In-reader switch (paged settings sheet): live on/off, saved as the
  // same account setting the Reader Settings page shows.
  const toggle = document.getElementById("paged-smart-panels");
  if (toggle) {
    document.getElementById("paged-smart-panels-row")?.removeAttribute("hidden");
    toggle.checked = smart;
    toggle.addEventListener("change", () => {
      smart = toggle.checked;
      panelDbg("toggle", { smart, scanning, focus, pending: pending && { page: pending.page, held: pending.held } });
      if (smart) scan();
      else {
        // hand the camera back whatever state it's in — on a panel, or
        // holding a page turn while detection runs (old page still up)
        clearFocus(focus.page);
        animUntil = 0;
        window.dispatchEvent(new Event("phx:fresco:refit"));
      }
      const csrf = document.querySelector('meta[name="csrf-token"]')?.content;
      fetch("/manga/settings/smart_panels", {
        method: "PUT",
        headers: { "Content-Type": "application/json", "x-csrf-token": csrf || "" },
        body: JSON.stringify({ enabled: smart })
      }).catch(() => {});
    });
  }

  {
    window.__pagedPanelStep = (dir, { page, doubleMode }) => {
      panelDbg("step", {
        dir, page, doubleMode, smart, focus, enabled,
        images: handle.getImages().map((i) => {
          const r = results.get(i.src);
          return `${i.id}:${i.naturalWidth || 0}:${r === undefined ? "none" : r === null ? "null" : r.panels.length}`;
        }).join(" ")
      });
      if (!smart) return false;
      if (doubleMode) { clearFocus(page); return false; }
      if (focus.page !== page) clearFocus(page);
      const hit = pageResult(page);
      const n = hit ? hit.res.panels.length : 0;
      if (n === 0) return false;
      let next = focus.idx + dir;
      // Nothing focused yet (fresh load, page fit on screen) and the panel
      // is the whole page: the page fit already shows it, so step past it.
      if (focus.idx < 0 && next === 0 && wholePage(hit, 0)) next = 1;
      if (next < 0 || next >= n) return false; // off either end: turn the page
      return focusPanel(page, next);
    };

    // Asked before a page turn: take the camera? Then the reader keeps the
    // page being left on screen and we glide straight across to the new
    // page's panel (waiting on its detection if need be).
    window.__pagedPanelTurn = (dir, { page, doubleMode }) => {
      if (!smart || doubleMode) return false;
      const hit = pageResult(page);
      return !hit || hit.res.panels.length > 0;
    };

    // A page turn just landed on `page`: open on its first panel going
    // forward, its last going back — or as soon as detection finishes.
    window.__pagedPanelLanded = (page, dir, { doubleMode, held, settle, refit }) => {
      const chapterStart = held && focus.page !== page && !pageImage(focus.page)?.naturalWidth;
      clearFocus(page);
      autoScale = handle.getTransform().s;
      if (!smart || doubleMode) { if (held) refit?.(); return; }
      // a fresh chapter has nothing sensible on screen to glide from
      if (chapterStart) offPageStart(page);
      if (landOn(page, dir, held, settle)) return;
      pending = {
        page, dir, held, settle, refit,
        timer: held ? setTimeout(() => {
          if (pending?.page !== page) return;
          pending = null;
          refit?.();
        }, HOLD_MS) : 0
      };
      scan();
    };

    // While the camera sits where we put it (or is gliding there), taps
    // and swipes still step; a pinch away from it is the user inspecting.
    window.__pagedPanelTapOk = () => {
      if (smart && pending?.held) return true;
      if (!smart || focus.idx < 0) return false;
      if (performance.now() < animUntil) return true;
      const s = handle.getTransform().s;
      return autoScale > 0 && Math.abs(s / autoScale - 1) < 0.03;
    };

    // The reader refits the page on resize / rotation; put the panel back.
    let resizeTimer = 0;
    window.addEventListener("resize", () => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => {
        if (smart && focus.idx >= 0) focusPanel(focus.page, focus.idx, false);
      }, 120);
    });
  }

  function onDetected(im) {
    if (!pending || `page-${pending.page}` !== im.id) return;
    if (!smart) { clearFocus(focus.page); return; }
    const { page, dir, held, settle, refit, timer } = pending;
    clearTimeout(timer);
    pending = null;
    if (!landOn(page, dir, held, settle) && held) refit?.();
  }

  let scanning = false;
  async function scan() {
    if ((!enabled && !smart) || scanning) return;
    scanning = true;
    try {
      const direction = window.__pagedDirection || "rtl";
      for (;;) {
        // nearest pages to the one being read first
        const near = focus.page || 1;
        const pageNo = (i) => parseInt((i.id.match(/^page-(\d+)$/) || [])[1] || "1e9", 10);
        const im = handle.getImages()
          .filter((i) => i.src && i.naturalWidth && !results.has(i.src))
          .sort((a, b) => Math.abs(pageNo(a) - near) - Math.abs(pageNo(b) - near))[0];
        if (!im) break;
        const el = container.querySelector(`img[data-image-id="${CSS.escape(im.id)}"]`);
        if (!el || !el.complete || !el.naturalWidth) { results.set(im.src, null); continue; }
        try {
          panelDbg("detect-start", { id: im.id, el: (el.currentSrc || el.src || "").slice(-60) });
          const res = await detectPanels(el, direction);
          panelDbg("detect-done", { id: im.id, panels: res.panels.length, ms: res.ms });
          results.set(im.src, res);
          console.debug(`[panels] ${im.id}: ${res.panels.length} panels, ${res.bits.length} bits` +
            `${res.bgDark ? " (dark gutters)" : ""} in ${res.ms}ms`);
        } catch (err) {
          results.set(im.src, { panels: [], bits: [], bgDark: false, ms: 0 });
          console.warn(`[panels] ${im.id}: detection failed`, err);
          panelDbg("detect-failed", { id: im.id, err: String(err && err.message || err) });
        }
        onDetected(im);
        render();
        if (!enabled && !smart) break;
      }
    } finally {
      scanning = false;
    }
  }

  handle.on("update-viewport", syncTransform);
  handle.on("resize", syncTransform);
  handle.on("image-loaded", () => {
    for (const [src, res] of results) if (res === null) results.delete(src);
    scan();
  });
  handle.on("sources-changed", () => { clearFocus(0); render(); scan(); });

  const icon =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="18" height="18">' +
    '<rect x="3" y="3" width="8" height="10" rx="1"/><rect x="13" y="3" width="8" height="6" rx="1"/>' +
    '<rect x="13" y="11" width="8" height="10" rx="1"/><rect x="3" y="15" width="8" height="6" rx="1"/></svg>';
  const btn = handle.appendNavButton?.(icon, enabled ? "Hide panels" : "Show panels", () => {
    enabled = !enabled;
    try { localStorage.setItem(STORAGE_KEY, enabled ? "1" : "0"); } catch (_) {}
    btn?.setTitle?.(enabled ? "Hide panels" : "Show panels");
    render();
    scan();
  });

  panelDbg("attach", { smart, enabled, toggle: !!toggle, images: handle.getImages().length });
  render();
  scan();
}


// TEMP diagnostic — smart panels events into the reader's debug log
// (/tmp/fresco_debug.log), same channel as the reader's kbDbg.
function panelDbg(step, data) {
  try {
    const url = document.querySelector("[data-debug-log-url]")?.dataset.debugLogUrl;
    const csrf = document.querySelector('meta[name="csrf-token"]')?.content;
    if (!url) return;
    fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", "x-csrf-token": csrf || "" },
      credentials: "same-origin",
      body: JSON.stringify({ event: "panel_debug", step, ts: Date.now(), ...data })
    }).catch(() => {});
  } catch (_) {}
}

function readSmartPanels() {
  if (new URLSearchParams(location.search).get("smartpanels") === "1") return true;
  return document.querySelector('meta[name="smart-panels"]')?.content === "1";
}

function currentPageFromUrl() {
  const n = parseInt(new URLSearchParams(location.search).get("page") || "1", 10);
  return n > 0 ? n : 1;
}

function readEnabled() {
  if (new URLSearchParams(location.search).get("panels") === "1") return true;
  try { return localStorage.getItem(STORAGE_KEY) === "1"; } catch (_) { return false; }
}

// points in canvas px — syncTransform projects them on screen
function poly(points, attrs) {
  const el = document.createElementNS(SVG_NS, "polygon");
  el.__pts = points;
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  return el;
}

function badge(n, color, x, y) {
  const g = document.createElementNS(SVG_NS, "g");
  g.__at = [x, y];
  const c = document.createElementNS(SVG_NS, "circle");
  c.setAttribute("cx", "14"); c.setAttribute("cy", "14"); c.setAttribute("r", "12");
  c.setAttribute("fill", color); c.setAttribute("stroke", "#fff"); c.setAttribute("stroke-width", "2");
  const t = document.createElementNS(SVG_NS, "text");
  t.setAttribute("x", "14"); t.setAttribute("y", "18.5");
  t.setAttribute("text-anchor", "middle");
  t.setAttribute("font-weight", "700"); t.setAttribute("font-size", "13");
  t.setAttribute("font-family", "system-ui, sans-serif");
  t.setAttribute("fill", "#fff");
  t.textContent = String(n);
  g.append(c, t);
  return g;
}

// ── Boot ───────────────────────────────────────────────────────────────

if (window.Fresco?.onViewerReady) {
  window.Fresco.onViewerReady(VIEWER_ID, attach);
}
