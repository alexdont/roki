// Panel detection core — pure (no DOM), so it runs in the panel Web
// Worker (panel_worker.js), on the main thread as a fallback, and
// headless under Node for tuning against real pages.
//
//   1. luminance → the page's gutter color from its border (white for
//      most manga, black for some)
//   2. "ink" = anything clearly not gutter-colored; dilated a little so
//      hairline breaks in panel borders don't leak
//   3. flood the gutter in from the page edges
//   4. every connected non-gutter region is a candidate
//   5. regions that art / SFX bridged across a gutter are split along
//      the best straight (possibly slanted) gutter line
//   6. big pieces are panels (convex hull = shape, so slanted panels
//      read right); small ones are "bits" — stray text / SFX / art
//      outside panels, kept because art escaping panels matters later

const PANEL_MIN_AREA = 0.006;   // of page area — below this it's a "bit"
const BIT_MIN_AREA = 0.0002;    // below this it's noise
// a lone balloon: small, roundish (an ellipse fills ~0.79 of its box),
// mostly one blank blob
const FLOAT_MAX = 0.05, FLOAT_FILL_MIN = 0.6, FLOAT_FILL = 0.9, FLOAT_BLOB = 0.5;

// Working resolution (long edge). Panels are big; this keeps a page
// fast while still resolving thin gutters.
export const WORK_SIZE = 900;

/**
 * Full-size RGBA page pixels (`nw`×`nh`) → shapes in natural-image px.
 * Shrinks to WORK_SIZE itself (bilinear) rather than trusting the
 * browser's canvas resampler: Safari and Chrome shrink differently, and
 * borderline gutters / balloon edges came out differently per device.
 */
export function detectFromImage(px, nw, nh, direction = "rtl") {
  const scale = Math.min(1, WORK_SIZE / Math.max(nw, nh));
  const W = Math.max(1, Math.round(nw * scale)), H = Math.max(1, Math.round(nh * scale));
  return detectFromPixels(scale < 1 ? bilinear(px, nw, nh, W, H, scale) : px, W, H, scale, direction);
}

export function bilinear(src, nw, nh, W, H, scale) {
  const out = new Uint8ClampedArray(W * H * 4);
  const at = (x, y, c) => src[(Math.min(nh - 1, Math.max(0, y)) * nw + Math.min(nw - 1, Math.max(0, x))) * 4 + c];
  for (let y = 0; y < H; y++) {
    const fy = (y + 0.5) / scale - 0.5, y0 = Math.floor(fy), ay = fy - y0;
    for (let x = 0; x < W; x++) {
      const fx = (x + 0.5) / scale - 0.5, x0 = Math.floor(fx), ax = fx - x0;
      const d = (y * W + x) * 4;
      for (let c = 0; c < 3; c++) {
        out[d + c] =
          (at(x0, y0, c) * (1 - ax) + at(x0 + 1, y0, c) * ax) * (1 - ay) +
          (at(x0, y0 + 1, c) * (1 - ax) + at(x0 + 1, y0 + 1, c) * ax) * ay;
      }
      out[d + 3] = 255;
    }
  }
  return out;
}

/**
 * The canvas-free core: RGBA pixels of the downscaled page (`W`×`H`,
 * `scale` = downscaled / natural) → shapes in natural-image pixels.
 * Split out so it runs headless (Node) for tuning against real pages.
 */
export function detectFromPixels(px, W, H, scale, direction = "rtl", debug = false) {
  const N = W * H;
  const lum = new Uint8Array(N);
  for (let i = 0, j = 0; i < N; i++, j += 4) {
    lum[i] = (px[j] * 77 + px[j + 1] * 150 + px[j + 2] * 29) >> 8;
  }

  // 1. gutter color from a 3px border frame
  let light = 0, dark = 0, edge = 0;
  const frame = 3;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      if (x >= frame && x < W - frame && y >= frame && y < H - frame) continue;
      const l = lum[y * W + x];
      if (l > 200) light++; else if (l < 55) dark++;
      edge++;
    }
  }
  const bgDark = dark > light * 1.5 && dark > edge * 0.4;

  // 2. ink mask, dilated (separable running max)
  let ink = new Uint8Array(N);
  for (let i = 0; i < N; i++) ink[i] = bgDark ? (lum[i] > 70 ? 1 : 0) : (lum[i] < 215 ? 1 : 0);
  // "paper": strictly gutter-colored (pure white / pure black). Thin
  // gutters must be paper — light art between parallel lines (railings,
  // blinds) is close but not paper.
  const paper = new Uint8Array(N);
  for (let i = 0; i < N; i++) paper[i] = bgDark ? (lum[i] < 30 ? 1 : 0) : (lum[i] > 238 ? 1 : 0);
  const inkRaw = ink;
  const r = Math.max(1, Math.round(W / 350));
  ink = dilate(ink, W, H, r);

  // 3. flood the gutter in from the page border (4-connected)
  const gutter = new Uint8Array(N);
  const stack = new Int32Array(N);
  let sp = 0;
  const seed = (i) => { if (!ink[i] && !gutter[i]) { gutter[i] = 1; stack[sp++] = i; } };
  for (let x = 0; x < W; x++) { seed(x); seed((H - 1) * W + x); }
  for (let y = 0; y < H; y++) { seed(y * W); seed(y * W + W - 1); }
  while (sp > 0) {
    const i = stack[--sp];
    const x = i % W;
    if (x > 0) seed(i - 1);
    if (x < W - 1) seed(i + 1);
    if (i >= W) seed(i - W);
    if (i < N - W) seed(i + W);
  }

  // 4. label connected non-gutter regions (bbox + area)
  const label = new Int32Array(N);
  const regions = [];
  for (let start = 0; start < N; start++) {
    if (gutter[start] || label[start]) continue;
    const id = regions.length + 1;
    let minX = W, minY = H, maxX = 0, maxY = 0, area = 0;
    label[start] = id; stack[0] = start; sp = 1;
    while (sp > 0) {
      const i = stack[--sp];
      const x = i % W, y = (i / W) | 0;
      area++;
      if (x < minX) minX = x; if (x > maxX) maxX = x;
      if (y < minY) minY = y; if (y > maxY) maxY = y;
      if (x > 0 && !gutter[i - 1] && !label[i - 1]) { label[i - 1] = id; stack[sp++] = i - 1; }
      if (x < W - 1 && !gutter[i + 1] && !label[i + 1]) { label[i + 1] = id; stack[sp++] = i + 1; }
      if (y > 0 && !gutter[i - W] && !label[i - W]) { label[i - W] = id; stack[sp++] = i - W; }
      if (y < H - 1 && !gutter[i + W] && !label[i + W]) { label[i + W] = id; stack[sp++] = i + W; }
    }
    regions.push({ id, cuts: [], minX, minY, maxX, maxY, area });
  }

  // 5. split regions that art / SFX bridged across a gutter
  const geo = { W, H, label, paper, inkRaw, inkD: ink, halo: r, lum, bgDark };
  const minPanelPx = PANEL_MIN_AREA * N;
  const pieces = [];
  for (const g of regions) {
    if (g.area >= minPanelPx) splitRegion(geo, g, minPanelPx, 0, pieces);
    else pieces.push(g);
  }
  for (let k = pieces.length - 1; k >= 0; k--) {
    if (pieces[k].area < minPanelPx) continue;
    // A slanted panel's biggest upright ruled rectangle stops short of
    // its slanted side; the bleed trim keeps the whole panel (the slant
    // edge is closed by the gutter) — prefer whichever keeps more panel.
    const peel = peelRuledRect(geo, pieces[k]), trim = trimToRuledBox(geo, pieces[k]);
    const peeled = peel && trim ? (trim[0].area > peel[0].area ? trim : peel) : peel || trim;
    if (peeled) pieces.splice(k, 1, ...peeled);
  }

  // 5b. drawn frames inside a piece split it: the frames are panels, the
  // art left outside them a borderless one
  const frames = findFrames(geo);
  for (let k = pieces.length - 1; k >= 0; k--) {
    if (pieces[k].area < minPanelPx) continue;
    const parts = splitByFrames(geo, pieces[k], frames, minPanelPx);
    if (parts) pieces.splice(k, 1, ...parts);
  }

  // 6. shape each piece from its row extents, back in natural-image px
  const inv = 1 / scale;
  const shapes = pieces
    .filter((g) => g.area / N >= BIT_MIN_AREA)
    .map((g) => {
      const pts = [];
      const rows = new Map(); // work-px row → [lo, hi], the real (non-convex) shape
      for (let y = g.minY; y <= g.maxY; y++) {
        let lo = -1, hi = -1;
        for (let x = g.minX; x <= g.maxX; x++) {
          if (inside(geo, g, x, y)) { if (lo < 0) lo = x; hi = x; }
        }
        if (lo >= 0) { pts.push(lo, y, hi + 1, y, lo, y + 1, hi + 1, y + 1); rows.set(y, [lo, hi + 1]); }
      }
      let box = { x0: g.minX, y0: g.minY, x1: g.maxX + 1, y1: g.maxY + 1 };
      if (g.frameRest) {
        // art left beside cut-out frames keeps hairline strips of their
        // borders: shape it from its main body only — per row its longest
        // unbroken run, then the biggest run of rows more than a sliver wide
        for (const y of rows.keys()) {
          let best = null, start = -1;
          for (let x = g.minX; x <= g.maxX + 1; x++) {
            const on = x <= g.maxX && inside(geo, g, x, y);
            if (on && start < 0) start = x;
            if (!on && start >= 0) {
              if (!best || x - start > best[1] - best[0]) best = [start, x];
              start = -1;
            }
          }
          if (best) rows.set(y, best);
        }
        const minW = REST_ROW_MIN * W;
        let best = null, cur = null, last = -9;
        for (const [y, [lo, hi]] of [...rows].sort((a, b) => a[0] - b[0])) {
          if (hi - lo < minW) continue;
          if (!cur || y - last > 2) { cur = { rows: [], mass: 0 }; }
          cur.rows.push([y, lo, hi]); cur.mass += hi - lo; last = y;
          if (!best || cur.mass > best.mass) best = cur;
        }
        if (best) {
          // and not a row far wider than the body (a frame's border line
          // left running along its edge)
          const widths = best.rows.map(([, lo, hi]) => hi - lo).sort((p, q) => p - q);
          const med = widths[widths.length >> 1];
          best.rows = best.rows.filter(([, lo, hi]) => hi - lo <= REST_ROW_WIDE * med);
          pts.length = 0; rows.clear();
          box = { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity };
          for (const [y, lo, hi] of best.rows) {
            pts.push(lo, y, hi, y, lo, y + 1, hi, y + 1); rows.set(y, [lo, hi]);
            box.x0 = Math.min(box.x0, lo); box.x1 = Math.max(box.x1, hi);
            box.y0 = Math.min(box.y0, y); box.y1 = Math.max(box.y1, y + 1);
          }
        }
      }
      const escapes = (g.escapes || []).map((e) => ({
        sure: e.sure,
        balloon: !!e.balloon,
        hull: convexHull(e.pts).map(([x, y]) => [x * inv, y * inv])
      }));
      const vx0 = Math.min(g.minX, ...(g.escapes || []).map((e) => e.minX));
      const vy0 = Math.min(g.minY, ...(g.escapes || []).map((e) => e.minY));
      const vx1 = Math.max(g.maxX + 1, ...(g.escapes || []).map((e) => e.maxX));
      const vy1 = Math.max(g.maxY + 1, ...(g.escapes || []).map((e) => e.maxY));
      const fill = g.area / ((g.maxX - g.minX + 1) * (g.maxY - g.minY + 1));
      const blob = g.area / N < FLOAT_MAX && fill >= FLOAT_FILL_MIN && fill < FLOAT_FILL ? paperBlob(geo, g) : 0;
      return {
        rows,
        floating: blob >= FLOAT_BLOB,
        frameRest: !!g.frameRest,
        bleed: !!g.bleed,
        x: box.x0 * inv, y: box.y0 * inv,
        w: (box.x1 - box.x0) * inv, h: (box.y1 - box.y0) * inv,
        area: g.area / N,
        hull: convexHull(pts).map(([x, y]) => [x * inv, y * inv]),
        // art escaping the panel (drawn over a neighbour), and the box a
        // panel view must show to include it
        escapes,
        view: { x: vx0 * inv, y: vy0 * inv, w: (vx1 - vx0) * inv, h: (vy1 - vy0) * inv }
      };
    });

  // bleed (tone / gradient outside a fully ruled panel) is background,
  // drawn like the stray bits
  const pool = mergeFrameRests(shapes.filter((s) => !s.bleed), W * inv, H * inv, scale);
  const merged = attachFloating(mergeSlivers(pool.filter((s) => s.area >= PANEL_MIN_AREA)), Math.max(W, H) * inv);
  // A "panel" lying wholly inside another one's box is something drawn in
  // it — a speech balloon cut loose when the page flood ran into an
  // open-edged panel's blank areas. It reads with its container.
  const nested = merged.filter((p) => merged.some((q) => q !== p && q.area > p.area && within(p, q, scale)));
  const panels = orderPanels(merged.filter((p) => !nested.includes(p)), direction);
  const bits = [...shapes.filter((s) => s.bleed), ...pool.filter((s) => s.area < PANEL_MIN_AREA), ...nested];
  for (const sh of [...shapes, ...pool]) { delete sh.rows; delete sh.frameRest; delete sh.floating; }
  return debug ? { panels, bits, bgDark, gutter, W, H } : { panels, bits, bgDark };
}

// ── Splitting merged panels ────────────────────────────────────────────
//
// When art crosses a gutter, two panels flood-fill as one region. The
// gutter is still there, just interrupted: a straight (possibly
// slanted) line through the region that runs mostly outside it is a cut.
// Panel interiors never count as "outside" — white inside a panel isn't
// reachable by the gutter flood — so cuts don't slice through panels.

const CUT_MIN = 0.45;       // gutter share of the line (vs. art bridging it)
const OPEN_SPAN = 0.25;     // ...or open gutter over this share of the line
const CUT_MIN_OPEN = 0.35;  // ...with at least this gutter share
const CUT_SLANT = 0.15;     // max slope as a fraction of the region span
const MAX_SPLIT_DEPTH = 6;
const SPLIT_MIN_AREA = 0.02; // each side of a cut keeps ≥ 2% of the page

// A piece = a labelled region narrowed by half-plane cuts.
function inside(geo, g, x, y) {
  if (geo.label[y * geo.W + x] !== g.id) return false;
  for (const r of g.rects || []) {
    const inRect = x >= r.l && x <= r.r && y >= r.t && y <= r.b;
    if (inRect !== r.keep) return false;
  }
  for (const q of g.quads || []) {
    if (inQuad(q.pts, x, y) !== q.keep) return false;
  }
  for (const c of g.cuts) {
    const side = (c.bx - c.ax) * (y - c.ay) - (c.by - c.ay) * (x - c.ax);
    if ((side > 0) !== c.keep) return false;
  }
  return true;
}

function splitRegion(geo, g, minPanelPx, depth, out) {
  const cut = depth < MAX_SPLIT_DEPTH && findCut(geo, g, minPanelPx);
  if (!cut) { out.push(g); return; }
  const halves = [true, false].map((keep) =>
    measure(geo, { id: g.id, rects: g.rects, cuts: [...g.cuts, { ...cut, keep }] }, g));
  // A big speech balloon is one blank blob inside a ruled-less outline;
  // its edge can pass for a gutter. Real gutters are ruled on both sides.
  const blob = Math.max(...halves.map((h) => paperBlob(geo, h)));
  if (blob >= FRAMED_BLOB) {
    const run = ruledRun(geo, cut);
    const balloonEdge = blob >= BALLOON_PIECE && (run < RULED_RUN || (blob >= BALLOON_PIECE_BIG && run < RULED_RUN_BIG));
    // inside one framed box: gutter evidence only from blank bands within
    // the panel (hair, balloons), no ruling, frame unbroken at both ends
    const inFrame = cut.open < FRAMED_OPEN && run < RULED_RUN && framedEnds(geo, g, cut) === 2;
    if (balloonEdge || inFrame) { out.push(g); return; }
  }
  const found = findEscapes(geo, g, cut, halves);
  halves.forEach((piece, i) => {
    // escapes found earlier follow whichever half their bridge is in
    const inherited = (g.escapes || []).filter((e) => inside(geo, piece, e.seedX, e.seedY));
    piece.escapes = [...inherited, ...found[i]];
    if (piece.area > 0) splitRegion(geo, piece, minPanelPx, depth + 1, out);
  });
}

// ── Escaping art ───────────────────────────────────────────────────────
//
// Where a figure leans out of her panel across the gutter, the cut
// between the two panels has a wide "bridge" of art. Each crossing
// gets an escape region reaching across the cut into the neighbour
// (the reach is estimated from the crossing's width — figures poke out
// about as far as they're wide — capped at 60% of the neighbour).
//
// Origin: her outline touches the background behind her, so there's no
// clean silhouette to trace. Instead compare, at growing distance from
// the gutter on each side, the art INSIDE the crossing span with the
// art just BESIDE it (the flanks). On the side she escaped into, the
// span looks like its surroundings again soon after the crossing (past
// the hat tip it's background); on her own side her body keeps it
// different for much longer. The side where the difference persists
// clearly longer is the origin, and only that panel claims the escape.
// When it isn't clear, both panels get it (marked unsure).

const ESCAPE_MIN_SPAN = 0.05; // crossing must cover this share of the cut
const ESCAPE_GAP = 3;         // samples of gutter tolerated inside a crossing
const ESCAPE_REACH = 0.6;     // reach into the neighbour, × crossing width
const ESCAPE_PAD = 4;         // px around the crossing, along the cut
const ESCAPE_MAX_DEPTH = 0.6; // ...but at most this share of the neighbour
const ORIGIN_SCAN = 300;      // px to profile on each side
const ORIGIN_STEP = 3;
const ORIGIN_SAME = 0.35;     // span vs flank difference that counts as "alike"
const ORIGIN_STREAK = 3;      // alike samples in a row that end the figure
const ORIGIN_RATIO = 2;       // origin must persist this many times longer
const ORIGIN_MIN = 30;        // ...and at least this far (px)

function findEscapes(geo, g, c, halves) {
  const found = [[], []];
  const lx = c.bx - c.ax, ly = c.by - c.ay, ll = Math.hypot(lx, ly) || 1;
  const ux = lx / ll, uy = ly / ll;          // along the cut
  const nx = -uy, ny = ux;                   // +normal points into halves[0]
  const n = Math.min(240, Math.max(24, Math.round(ll / 2)));

  // crossings: clusters of bridge samples (inked, inside the region,
  // not thin gutter), tolerating short gaps between strokes
  const clusters = [];
  let cur = null, gap = 0;
  for (let k = 0; k <= n; k++) {
    const x = c.ax + (lx * k) / n, y = c.ay + (ly * k) / n;
    // a crossing puts real ink strokes into the gutter; a hairline gutter
    // blurred at work size is light gray, not ink
    const rx = Math.round(x), ry = Math.round(y);
    const inked = [-1, 0, 1].some((d) => {
      const qx = Math.round(x + nx * d), qy = Math.round(y + ny * d);
      return qx >= 0 && qy >= 0 && qx < geo.W && qy < geo.H && geo.inkRaw[qy * geo.W + qx] === 1;
    });
    const bridge = inked && inside(geo, g, rx, ry) && !thinGutter(geo, x, y, nx, ny);
    if (bridge) {
      if (!cur || gap > ESCAPE_GAP) clusters.push((cur = { from: k, to: k, hits: 0 }));
      cur.to = k; cur.hits++; gap = 0;
    } else if (cur) gap++;
  }

  // parts of one figure (head, then a raised arm) cross a little apart:
  // join crossings whose gap is under half the wider one
  for (let k = clusters.length - 1; k > 0; k--) {
    const a = clusters[k - 1], b = clusters[k];
    const gapK = b.from - a.to;
    if (gapK <= 0.5 * Math.max(a.to - a.from, b.to - b.from)) {
      a.to = b.to; a.hits += b.hits;
      clusters.splice(k, 1);
    }
  }

  // how deep each half reaches along the normal (from the cut line)
  const depthOf = (piece, dir) => {
    let d = 0;
    for (const [x, y] of [[piece.minX, piece.minY], [piece.maxX, piece.minY], [piece.minX, piece.maxY], [piece.maxX, piece.maxY]]) {
      d = Math.max(d, dir * ((x - c.ax) * nx + (y - c.ay) * ny));
    }
    return d;
  };

  // Balloons first: a speech balloon straddling the gutter is a closed
  // white shape we can trace exactly, and its owner is the side holding
  // most of it. Crossings a balloon explains skip the generic estimate.
  const balloons = findBalloons(geo, g, c, n, nx, ny, halves);
  for (const b of balloons) {
    if (b.joined) {
      // the poke into halves[i] goes to the panel on the other side
      [0, 1].forEach((i) => {
        const sh = b.sides[i];
        if (sh) found[1 - i].push({ sure: false, balloon: true, ...sh, seedX: b.seeds[1 - i][0], seedY: b.seeds[1 - i][1] });
      });
      continue;
    }
    [0, 1].forEach((i) => {
      if (b.owner === -1 || b.owner === i) {
        found[i].push({ sure: b.owner === i, balloon: true, ...b.shape, seedX: b.seeds[i][0], seedY: b.seeds[i][1] });
      }
    });
  }
  const explained = (cl) => balloons.some((b) => {
    const over = Math.min(cl.to, b.to) - Math.max(cl.from, b.from);
    return over >= 0.5 * (cl.to - cl.from + 1);
  });

  for (const cl of clusters) {
    if (cl.hits < Math.max(4, ESCAPE_MIN_SPAN * (n + 1))) continue;
    if (explained(cl)) continue;
    const t0 = (cl.from / n) * ll - ESCAPE_PAD, t1 = (cl.to / n) * ll + ESCAPE_PAD;
    const width = t1 - t0;
    const at = (t, d) => [c.ax + ux * t + nx * d, c.ay + uy * t + ny * d];

    // origin: which side the figure keeps standing out in for longer
    const persist = [1, -1].map((dir, i) => persistence(geo, halves[i], c, ux, uy, nx * dir, ny * dir, t0, t1));
    const origin =
      persist[0] >= ORIGIN_MIN && persist[0] >= ORIGIN_RATIO * persist[1] ? 0 :
      persist[1] >= ORIGIN_MIN && persist[1] >= ORIGIN_RATIO * persist[0] ? 1 : -1;

    [1, -1].forEach((dir, i) => {
      // reach into halves[i]; the view of halves[1 - i] gets it — unless
      // the origin is known and it's halves[i] itself
      if (origin === i) return;
      const reach = Math.min(ESCAPE_REACH * width, ESCAPE_MAX_DEPTH * depthOf(halves[i], dir));
      if (reach < 4) return;
      const poly = [at(t0, 0), at(t1, 0), at(t1, dir * reach), at(t0, dir * reach)]
        .map(([x, y]) => [Math.max(0, Math.min(geo.W, x)), Math.max(0, Math.min(geo.H, y))]);
      const [sx, sy] = at((t0 + t1) / 2, -dir * 3); // a point on the owner's side
      found[1 - i].push({
        sure: origin === 1 - i,
        pts: poly.flat(),
        minX: Math.min(...poly.map((q) => q[0])), maxX: Math.max(...poly.map((q) => q[0])),
        minY: Math.min(...poly.map((q) => q[1])), maxY: Math.max(...poly.map((q) => q[1])),
        seedX: Math.round(sx), seedY: Math.round(sy)
      });
    });
  }
  return found;
}

// ── Balloons across a cut ──────────────────────────────────────────────

const BALLOON_MIN = 0.0015;   // of the page — smaller white pockets are noise
const BALLOON_MAX = 0.06;     // a flood past this leaked: not a closed balloon
const BALLOON_SIDE = 0.12;    // each side of the cut must hold this much of it
const BALLOON_OWNER = 1.5;    // owner side must hold this many times more
const BALLOON_WAIST = 0.5;    // crossing ≥ this share of its length along the cut
const BALLOON_NECK_GROW = 1.3; // ...else two joined: a neck ends where it widens this much
const BALLOON_NECK_MAX = 40;   // px

// Flood the white interior from every un-inked point where the cut
// crosses the region (dilated ink as walls, so text letters are islands
// and hairline gaps in the outline stay shut). A bounded flood with a
// real share on both sides of the cut is a balloon straddling it.
function findBalloons(geo, g, c, n, nx, ny, halves) {
  const { W, H, inkD } = geo;
  const lx = c.bx - c.ax, ly = c.by - c.ay;
  const page = W * H, cap = BALLOON_MAX * page;
  const visited = new Uint8Array(W * H);
  const side = (x, y) => (c.bx - c.ax) * (y - c.ay) - (c.by - c.ay) * (x - c.ax) > 0;
  const out = [];

  for (let k = 0; k <= n; k++) {
    const sx = Math.round(c.ax + (lx * k) / n), sy = Math.round(c.ay + (ly * k) / n);
    if (sx < 0 || sy < 0 || sx >= W || sy >= H) continue;
    const s0 = sy * W + sx;
    if (visited[s0] || inkD[s0] || geo.label[s0] !== g.id) continue;

    const stack = [s0];
    const px = [];
    visited[s0] = 1;
    let leaked = false;
    while (stack.length) {
      const i = stack.pop();
      px.push(i);
      if (px.length > cap) { leaked = true; break; }
      const x = i % W, y = (i / W) | 0;
      for (const [xx, yy] of [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]) {
        if (xx < 0 || yy < 0 || xx >= W || yy >= H) { leaked = true; continue; }
        const j = yy * W + xx;
        if (!visited[j] && !inkD[j] && geo.label[j] === g.id) { visited[j] = 1; stack.push(j); }
      }
    }
    if (leaked || px.length < BALLOON_MIN * page) continue;

    // share on each side of the cut; halves[0] is the side() === true one
    let a = 0;
    const rows = new Map();
    for (const i of px) {
      const x = i % W, y = (i / W) | 0;
      if (side(x, y)) a++;
      const r = rows.get(y);
      if (r) { if (x < r[0]) r[0] = x; if (x > r[1]) r[1] = x; } else rows.set(y, [x, x]);
    }
    const b = px.length - a;
    if (Math.min(a, b) < BALLOON_SIDE * px.length) continue;

    // shape: row extents grown by the outline (walls are dilated ink)
    const pad = geo.halo + 3;
    const pts = [];
    let minX = W, minY = H, maxX = 0, maxY = 0;
    for (const [y, [x0, x1]] of rows) {
      pts.push(x0 - pad, y - pad, x1 + pad, y - pad, x0 - pad, y + pad, x1 + pad, y + pad);
      minX = Math.min(minX, x0 - pad); maxX = Math.max(maxX, x1 + pad);
      minY = Math.min(minY, y - pad); maxY = Math.max(maxY, y + pad);
    }
    // where on the cut it sits (sample indices), for "explained" checks
    let from = n, to = 0;
    for (let q = 0; q <= n; q++) {
      const qx = Math.round(c.ax + (lx * q) / n), qy = Math.round(c.ay + (ly * q) / n);
      for (let d = -2; d <= 2; d++) {
        const ex = Math.round(qx + nx * d), ey = Math.round(qy + ny * d);
        if (ex >= 0 && ey >= 0 && ex < W && ey < H && rows.has(ey) && ex >= rows.get(ey)[0] - pad && ex <= rows.get(ey)[1] + pad) {
          from = Math.min(from, q); to = Math.max(to, q); break;
        }
      }
    }
    // a point of the balloon inside each half (for escape inheritance)
    const seeds = [halves[0], halves[1]].map((h) => {
      const i = px.find((q) => inside(geo, h, q % W, (q / W) | 0));
      return i === undefined ? [-1, -1] : [i % W, (i / W) | 0];
    });
    const owner = a >= BALLOON_OWNER * b ? 0 : b >= BALLOON_OWNER * a ? 1 : -1;
    // Two balloons joined through a gap in the gutter pinch to a narrow
    // neck where they cross the cut; one balloon straddling the border
    // crosses at nearly its full length.
    const ll = Math.hypot(lx, ly), ux = lx / ll, uy = ly / ll;
    let lo = Infinity, hi = -Infinity;
    for (const i of px) {
      const t = ((i % W) - c.ax) * ux + (((i / W) | 0) - c.ay) * uy;
      if (t < lo) lo = t; if (t > hi) hi = t;
    }
    if (((to - from) / n) * ll < BALLOON_WAIST * (hi - lo)) {
      // Each panel gets the stretch of the other's balloon that pokes over
      // the border — from the cut until the shape widens into the other
      // balloon proper — marked unsure, so it's framed and shown, but
      // the other balloon's text isn't pulled into view.
      const nl = Math.hypot(nx, ny) || 1;
      const prof = new Map(); // signed distance → [min t, max t]
      for (const i of px) {
        const x = i % W, y = (i / W) | 0;
        const t = (x - c.ax) * ux + (y - c.ay) * uy;
        const d = Math.round(((x - c.ax) * nx + (y - c.ay) * ny) / nl);
        const e = prof.get(d);
        if (e) { if (t < e[0]) e[0] = t; if (t > e[1]) e[1] = t; } else prof.set(d, [t, t]);
      }
      const w0 = prof.has(0) ? prof.get(0)[1] - prof.get(0)[0] : 0;
      const depth = (dir) => {
        let d = 0;
        while (d < BALLOON_NECK_MAX && prof.has(dir * (d + 1))) {
          const e = prof.get(dir * (d + 1));
          if (e[1] - e[0] > BALLOON_NECK_GROW * w0) break;
          d++;
        }
        return d;
      };
      const reach = [depth(1), depth(-1)]; // halves[0] lies on +normal
      const pad = geo.halo + 3;
      const sides = [0, 1].map((k) => {
        const dir = k === 0 ? 1 : -1, pts = [];
        let minX = W, minY = H, maxX = 0, maxY = 0;
        for (const [d, [t0, t1]] of prof) {
          if (d * dir < 0 || d * dir > reach[k]) continue;
          for (const t of [t0, t1]) {
            const x0 = c.ax + ux * t + (nx / nl) * d, y0 = c.ay + uy * t + (ny / nl) * d;
            // grown by the outline, like a traced balloon
            for (const [x, y] of [[x0 - pad, y0 - pad], [x0 + pad, y0 - pad], [x0 - pad, y0 + pad], [x0 + pad, y0 + pad]]) {
              pts.push(x, y);
              minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y);
            }
          }
        }
        return pts.length >= 6 ? { pts, minX, minY, maxX, maxY } : null;
      });
      const seeds = [halves[0], halves[1]].map((h) => {
        const i = px.find((q) => inside(geo, h, q % W, (q / W) | 0));
        return i === undefined ? [-1, -1] : [i % W, (i / W) | 0];
      });
      out.push({ joined: true, sides, seeds, from, to });
      continue;
    }
    out.push({ owner, from, to, seeds, shape: { pts, minX, minY, maxX, maxY } });
  }
  return out;
}

// How far (px) from the cut, into one half, the crossing span keeps
// looking different from its flanks: mean luminance + ink density of
// the span band vs. bands just beside it, at each distance. Ends at the
// first ORIGIN_STREAK alike samples in a row.
function persistence(geo, half, c, ux, uy, nx, ny, t0, t1) {
  const { W, H, lum, inkRaw } = geo;
  const fw = Math.max(20, 0.5 * (t1 - t0));
  const band = (ta, tb, d) => {
    let n = 0, L = 0, I = 0;
    for (let t = ta; t <= tb; t += 2) {
      const x = Math.round(c.ax + ux * t + nx * d), y = Math.round(c.ay + uy * t + ny * d);
      if (x < 0 || y < 0 || x >= W || y >= H || !inside(geo, half, x, y)) continue;
      n++; L += lum[y * W + x]; I += inkRaw[y * W + x];
    }
    return { n, L, I };
  };
  let alike = 0, last = 0;
  for (let d = ORIGIN_STEP; d <= ORIGIN_SCAN; d += ORIGIN_STEP) {
    const a = band(t0, t1, d);
    const f1 = band(t0 - fw, t0 - 2, d), f2 = band(t1 + 2, t1 + fw, d);
    const fn = f1.n + f2.n;
    if (!a.n) break;     // ran out of the half
    if (!fn) continue;   // flanks still in the gutter beside the crossing
    const diff = Math.abs(a.L / a.n - (f1.L + f2.L) / fn) / 255 + Math.abs(a.I / a.n - (f1.I + f2.I) / fn);
    if (diff < ORIGIN_SAME) { if (++alike >= ORIGIN_STREAK) break; }
    else { alike = 0; last = d; }
  }
  return last;
}

// A cut that leaves one side mostly one blank blob may be splitting a
// speech balloon off its panel. Real gutters still show as a long,
// unbroken stretch of blank band between two straight borders (a
// balloon crossing interrupts it, but leaves long runs either side); a
// balloon's edge or a hair line only gives short ones.
const BALLOON_PIECE = 0.3;      // biggest blank blob share of a half
const BALLOON_PIECE_BIG = 0.55; // ...a half that's essentially a balloon
const RULED_RUN = 0.25;         // longest ruled stretch, share of the cut
const RULED_RUN_BIG = 0.4;      // ...demanded for an essentially-balloon half
const RULED_JITTER = 2;         // px
const FRAMED_BLOB = 0.2;        // blob share from which the framed-box test applies
const FRAMED_OPEN = 0.5;        // ...and the cut's open-gutter share below this
const FRAME_HALF = 10;          // px each side of the cut checked for a frame line
const FRAME_COVER = 0.9;
const FRAME_PROBE = 8;          // px around where the cut leaves the piece

// Ends of the cut where a drawn frame line runs straight across it.
// A real gutter breaks the frame where it meets it (a blank gap the
// gutter's width); a cut through one panel crosses that panel's own,
// unbroken top / bottom line. Checked near each end, where the cut
// leaves the piece.
function framedEnds(geo, g, c) {
  const { W, H, lum } = geo;
  const lx = c.bx - c.ax, ly = c.by - c.ay, ll = Math.hypot(lx, ly) || 1;
  const ux = lx / ll, uy = ly / ll, nx = -uy, ny = ux;
  const dark = (x, y) => {
    const xi = Math.round(x), yi = Math.round(y);
    return xi >= 0 && yi >= 0 && xi < W && yi < H && lum[yi * W + xi] < LINE_DARK;
  };
  // a dark line across the cut at distance t from the start: every
  // sample along the normal dark (a line can be 2-3 px thick, so the
  // sample may sit one px either side)
  const across = (t) => {
    let n = 0;
    for (let d = -FRAME_HALF; d <= FRAME_HALF; d++) {
      const x = c.ax + ux * t + nx * d, y = c.ay + uy * t + ny * d;
      if (dark(x, y) || dark(x + ux, y + uy) || dark(x - ux, y - uy)) n++;
    }
    return n >= FRAME_COVER * (2 * FRAME_HALF + 1);
  };
  // where the cut is inside the piece: first / last such sample
  let first = -1, last = -1;
  for (let t = 0; t <= ll; t++) {
    if (inside(geo, g, Math.round(c.ax + ux * t), Math.round(c.ay + uy * t))) { if (first < 0) first = t; last = t; }
  }
  if (first < 0) return 0;
  let ends = 0;
  for (const [from, dir] of [[first, 1], [last, -1]]) {
    for (let k = -FRAME_PROBE; k <= FRAME_PROBE; k++) {
      if (across(from + dir * k)) { ends++; break; }
    }
  }
  return ends;
}

function ruledRun(geo, c) {
  return ruledStats(geo, c).run;
}

// Per sample on the cut (blank points only — art bridging is skipped):
// walk out both ways to the first dark pixel. A real gutter is a narrow
// blank band between two straight borders, so both hits land at a
// steady distance and close together; a balloon's edge or a hair line
// gives one steady side at most, or a band far too wide.
function ruledStats(geo, c) {
  const { W, H, lum } = geo;
  if (geo.bgDark) return { run: 1 };
  const lx = c.bx - c.ax, ly = c.by - c.ay, ll = Math.hypot(lx, ly) || 1;
  const ux = lx / ll, uy = ly / ll, nx = -uy, ny = ux;
  const hit = (x0, y0, side) => {
    for (let d = 1; d <= GUTTER_MAX; d++) {
      const xx = Math.round(x0 + nx * side * d), yy = Math.round(y0 + ny * side * d);
      if (xx < 0 || yy < 0 || xx >= W || yy >= H) return null;
      if (lum[yy * W + xx] < LINE_DARK) return d;
    }
    return null;
  };
  const both = [];   // [a, b, sample index]
  let samples = 0, k = 0;
  for (let t = 0; t <= ll; t += 2, k++) {
    const x0 = c.ax + ux * t, y0 = c.ay + uy * t;
    const xi = Math.round(x0), yi = Math.round(y0);
    if (xi < 0 || yi < 0 || xi >= W || yi >= H || lum[yi * W + xi] < 200) continue;
    samples++;
    const a = hit(x0, y0, 1), b = hit(x0, y0, -1);
    if (a != null && b != null) both.push([a, b, k]);
  }
  const total = k;
  if (samples < 8 || !both.length) return { run: 0 };
  const med = (k) => { const v = both.map((p) => p[k]).sort((x, y) => x - y); return v[v.length >> 1]; };
  const ma = med(0), mb = med(1);
  const ok = both.filter(([a, b]) => Math.abs(a - ma) <= RULED_JITTER && Math.abs(b - mb) <= RULED_JITTER);
  // longest unbroken stretch of steady samples (short gaps allowed)
  let run = 0, best = 0, prev = -99;
  for (const [, , i] of ok) { run = i - prev <= 3 ? run + (i - prev) : 1; prev = i; best = Math.max(best, run); }
  return { run: best / total };
}

// Share of the piece covered by its single biggest connected patch of
// blank paper — a speech balloon's inside.
function paperBlob(geo, piece) {
  const { W } = geo;
  const seen = new Uint8Array(W * geo.H);
  const stack = [];
  let best = 0;
  for (let y = piece.minY; y <= piece.maxY; y++) {
    for (let x = piece.minX; x <= piece.maxX; x++) {
      const i0 = y * W + x;
      if (seen[i0] || !geo.paper[i0] || !inside(geo, piece, x, y)) continue;
      let n = 0;
      seen[i0] = 1; stack.push(i0);
      while (stack.length) {
        const i = stack.pop(); n++;
        const cx = i % W, cy = (i / W) | 0;
        for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
          const xx = cx + dx, yy = cy + dy;
          if (xx < piece.minX || xx > piece.maxX || yy < piece.minY || yy > piece.maxY) continue;
          const j = yy * W + xx;
          if (seen[j] || !geo.paper[j] || !inside(geo, piece, xx, yy)) continue;
          seen[j] = 1; stack.push(j);
        }
      }
      if (n > best) best = n;
    }
  }
  return piece.area ? best / piece.area : 0;
}

// Recompute bbox + area for a piece within its parent's bbox.
function measure(geo, piece, parent) {
  let minX = geo.W, minY = geo.H, maxX = 0, maxY = 0, area = 0, paper = 0;
  for (let y = parent.minY; y <= parent.maxY; y++) {
    for (let x = parent.minX; x <= parent.maxX; x++) {
      if (!inside(geo, piece, x, y)) continue;
      area++;
      paper += geo.paper[y * geo.W + x];
      if (x < minX) minX = x; if (x > maxX) maxX = x;
      if (y < minY) minY = y; if (y > maxY) maxY = y;
    }
  }
  return { ...piece, minX, minY, maxX, maxY, area, paper: area ? paper / area : 0 };
}

// Best gutter line across the piece, or null. Scans near-horizontal
// lines (left edge → right edge) and near-vertical ones (top → bottom).
// A real gutter has the piece on BOTH sides of it, so each sample is:
//   gutter  — outside the piece, with piece within SANDWICH px on both
//             sides (two panels facing each other across the line)
//   bridge  — inside the piece (art crossing the gutter)
//   neither — open page / another region: ignored
// A sample inside the piece still counts as gutter when it sits in a
// thin band of blank page with ink close on both sides (`thinGutter`):
// thin gutters the dilated flood sealed shut. White sky inside a panel
// fails that test — no ink near on both sides.
// score = gutter / (gutter + bridge). Lines along an open edge have no
// sandwiched samples, so they can't win; a gutter that art crosses for
// a stretch still scores high. The best line that also leaves a
// panel-sized area on both sides is the cut.
const SANDWICH = [3, 6, 10, 15];
const GUTTER_MAX = 18;       // widest gutter band, in work-size px

function thinGutter(geo, x, y, nx, ny) {
  const blank = (d) => {
    const xx = Math.round(x + nx * d), yy = Math.round(y + ny * d);
    if (xx < 0 || yy < 0 || xx >= geo.W || yy >= geo.H) return null; // page edge
    return geo.paper[yy * geo.W + xx] === 1;
  };
  if (!blank(0)) return null;
  const edge = [];
  for (const dir of [1, -1]) {
    let d = 1;
    for (; d <= GUTTER_MAX; d++) {
      const b = blank(dir * d);
      if (b === null) return null;
      if (!b) break;
    }
    if (d > GUTTER_MAX) return null;
    edge.push(d);
  }
  return edge[0] + edge[1] - 1 <= GUTTER_MAX ? edge : null;
}

// Thin-gutter samples only count in straight runs: consecutive samples
// whose band edges stay put (a gutter between two ruled borders), at
// least GUTTER_RUN long. Gaps inside art are short and wobbly.
const GUTTER_RUN = 6;
const EDGE_JITTER = 2;
const MIN_GUTTER_SPAN = 0.3; // sandwiched gutter must cover this much of the line
const BRIDGE_BLANK = 0.5;    // weight of a blank (balloon) sample bridging the line

function findCut(geo, g, minPanelPx) {
  const bw = g.maxX - g.minX + 1, bh = g.maxY - g.minY + 1;
  const cands = [];
  const hit = (x, y) => x >= 0 && y >= 0 && x < geo.W && y < geo.H && inside(geo, g, x, y);
  const consider = (ax, ay, bx, by, len) => {
    const n = Math.min(160, Math.max(24, len >> 2));
    // unit normal to the line
    const lx = bx - ax, ly = by - ay, ll = Math.hypot(lx, ly) || 1;
    const nx = -ly / ll, ny = lx / ll;
    let gutterN = 0, bridge = 0, open = 0; // open: real gutter outside the region
    let run = 0, prev = null; // current straight thin-gutter run
    const endRun = () => {
      if (run >= GUTTER_RUN) gutterN += run; else bridge += run;
      run = 0; prev = null;
    };
    for (let k = 0; k <= n; k++) {
      const x = ax + (lx * k) / n, y = ay + (ly * k) / n;
      if (hit(Math.round(x), Math.round(y))) {
        const e = thinGutter(geo, x, y, nx, ny);
        if (e && (!prev || (Math.abs(e[0] - prev[0]) <= EDGE_JITTER && Math.abs(e[1] - prev[1]) <= EDGE_JITTER))) {
          run++; prev = e;
        } else {
          endRun();
          // blank paper inside the region (a balloon straddling the
          // gutter) only half counts against the cut — art crossing it is
          // the real evidence of no gutter
          if (e) { run = 1; prev = e; } else bridge += geo.paper[Math.round(y) * geo.W + Math.round(x)] ? BRIDGE_BLANK : 1;
        }
        continue;
      }
      endRun();
      let pos = false, neg = false;
      for (const d of SANDWICH) {
        if (!pos && hit(Math.round(x + nx * d), Math.round(y + ny * d))) pos = true;
        if (!neg && hit(Math.round(x - nx * d), Math.round(y - ny * d))) neg = true;
        if (pos && neg) break;
      }
      if (pos && neg) { gutterN++; open++; }
    }
    endRun();
    if (gutterN < MIN_GUTTER_SPAN * (n + 1)) return;
    const score = gutterN / (gutterN + bridge);
    // a long stretch of real open gutter is strong evidence on its own,
    // even where a big figure's art crosses the rest of the line
    const openSpan = open / (n + 1);
    if (score >= CUT_MIN || (openSpan >= OPEN_SPAN && score >= CUT_MIN_OPEN)) {
      cands.push({ ax, ay, bx, by, score, open: open / gutterN });
    }
  };

  // near-horizontal: (minX, yA) → (maxX, yA + d)
  const marginY = Math.max(6, Math.round(bh * 0.08));
  const maxDy = Math.round(bw * CUT_SLANT), stepDy = Math.max(2, Math.round(maxDy / 8));
  for (let yA = g.minY + marginY; yA <= g.maxY - marginY; yA += 3) {
    for (let d = -maxDy; d <= maxDy; d += stepDy) {
      const yB = yA + d;
      if (yB < g.minY + marginY || yB > g.maxY - marginY) continue;
      consider(g.minX, yA, g.maxX, yB, bw);
    }
  }
  // near-vertical: (xA, minY) → (xA + d, maxY)
  const marginX = Math.max(6, Math.round(bw * 0.08));
  const maxDx = Math.round(bh * CUT_SLANT), stepDx = Math.max(2, Math.round(maxDx / 8));
  for (let xA = g.minX + marginX; xA <= g.maxX - marginX; xA += 3) {
    for (let d = -maxDx; d <= maxDx; d += stepDx) {
      const xB = xA + d;
      if (xB < g.minX + marginX || xB > g.maxX - marginX) continue;
      consider(xA, g.minY, xB, g.maxY, bh);
    }
  }

  cands.sort((p, q) => q.score - p.score);
  const minSide = Math.max(SPLIT_MIN_AREA * geo.W * geo.H, g.area * 0.1);
  for (const c of cands.slice(0, 12)) {
    let a = 0, b = 0;
    for (let y = g.minY; y <= g.maxY; y++) {
      for (let x = g.minX; x <= g.maxX; x++) {
        if (!inside(geo, g, x, y)) continue;
        if ((c.bx - c.ax) * (y - c.ay) - (c.by - c.ay) * (x - c.ax) > 0) a++; else b++;
      }
    }
    if (Math.min(a, b) >= minSide) return c;
  }
  return null;
}

// ── Frames ─────────────────────────────────────────────────────────────
//
// The gutter tells panels apart only where there is one. Some layouts
// have none on a side: a borderless panel (figures on open page) sitting
// on a row of boxed panels, or two panels split by one drawn line with a
// figure overlapping it. Their frames are still drawn: long, thin,
// straight lines. Find those across the page, close them into
// four-sided frames, and let a frame split whatever piece it sits in.
//
// A frame needs three solidly drawn sides; the fourth may be half
// hidden (a figure drawn over it). At least two sides must face open
// page just outside — a window or picture frame drawn inside art has
// art all round it.

const FRAME_SEG_MIN = 0.06;     // line segment, share of the page's long side
const FRAME_GAP = 3;            // px gap tolerated inside a segment
const FRAME_H_SLANT = 0.06;     // horizontals: max slope
const FRAME_V_SLANT = 0.3;      // verticals: max slope (slanted dividers)
const FRAME_LINES = 50;
const FRAME_SIDES = 24;         // side candidates tried per top / bottom pair         // longest lines kept per direction
const FRAME_STRONG = 0.85;      // three sides at least this drawn
const FRAME_WEAK = 0.5;         // ...the fourth at least this
const FRAME_SIDE_MIN = 0.06;    // each side ≥ this share of the long side
const FRAME_CORNER = 12;        // px slack where sides meet
const FRAME_OPEN = 0.6;         // a side "faces page" with this share of paper outside
const FRAME_OPEN_SIDES = 2;
const FRAME_GUTTER_IN = 0.3;
const FRAME_RUN_ON = 16;
const FRAME_RUN_FAN = 0.06;     // ± slope tried when following a side past its corner        // px past a corner checked for a frame line running on
const FRAME_INTERIOR_GUTTER = 0.85; // a row / column of the inside this blank = a gutter band    // max share of a side's inner band that's open gutter
const FRAME_BOUND = 0.7;        // a side bounds the piece when this much beyond it is outside
const FRAME_IN = 0.9;           // a frame splits a piece when this much of it lies in the piece
const FRAME_ALL = 0.85;         // ...but not when it is (nearly) the whole piece
const FRAME_REST = 0.1;         // a single frame needs this much art left beside it
const REST_ROW_WIDE = 1.6;     // ...or wider than this × the body's median row
const REST_ROW_MIN = 0.03;      // leftover rows narrower than this (of page width) are slivers

function inQuad(pts, x, y) {
  let sign = 0;
  for (let i = 0; i < 4; i++) {
    const [ax, ay] = pts[i], [bx, by] = pts[(i + 1) % 4];
    const c = (bx - ax) * (y - ay) - (by - ay) * (x - ax);
    if (c === 0) continue;
    if (sign === 0) sign = Math.sign(c);
    else if (Math.sign(c) !== sign) return false;
  }
  return true;
}

function findFrames(geo) {
  const { W, H, lum, paper } = geo;
  if (geo.bgDark) return [];
  const L = Math.max(W, H);

  // border pixels: dark, with light within a few px on some side
  const mask = new Uint8Array(W * H);
  for (let y = 1; y < H - 1; y++) {
    for (let x = 1; x < W - 1; x++) {
      const i = y * W + x;
      if (lum[i] >= LINE_DARK) continue;
      let lit = false;
      for (let d = 1; d <= 4 && !lit; d++) {
        if (x - d >= 0 && lum[i - d] > LINE_LIGHT) lit = true;
        else if (x + d < W && lum[i + d] > LINE_LIGHT) lit = true;
        else if (y - d >= 0 && lum[i - d * W] > LINE_LIGHT) lit = true;
        else if (y + d < H && lum[i + d * W] > LINE_LIGHT) lit = true;
      }
      if (lit) mask[i] = 1;
    }
  }
  // ±1 px tolerance baked in, so a lookup is one read
  const dm = new Uint8Array(W * H);
  for (let y = 1; y < H - 1; y++) {
    for (let x = 1; x < W - 1; x++) {
      const i = y * W + x;
      dm[i] = mask[i] | mask[i - 1] | mask[i + 1] | mask[i - W] | mask[i + W];
    }
  }
  const at = (x, y) => {
    const xi = (x + 0.5) | 0, yi = (y + 0.5) | 0;
    return xi < 1 || yi < 1 || xi >= W - 1 || yi >= H - 1 ? 0 : dm[yi * W + xi];
  };

  // straight runs along lines pos(t) = o + s·(t − mid)
  const sweep = (horizontal) => {
    const span = horizontal ? W : H, across = horizontal ? H : W, mid = span / 2;
    const maxS = horizontal ? FRAME_H_SLANT : FRAME_V_SLANT, step = horizontal ? 0.01 : 0.02;
    const minLen = FRAME_SEG_MIN * L;
    const segs = [];
    for (let s = -maxS; s <= maxS + 1e-9; s += step) {
      for (let o = 1; o < across - 1; o++) {
        let a = -1, b = -1, gap = 0;
        const flush = () => { if (a >= 0 && b - a + 1 >= minLen) segs.push({ o, s, a, b, len: b - a + 1 }); a = -1; gap = 0; };
        for (let t = 0; t < span; t++) {
          const u = o + s * (t - mid);
          if (u < 1 || u >= across - 1) { flush(); continue; }
          const ui = (u + 0.5) | 0;
          const hit = horizontal ? dm[ui * W + t] : dm[t * W + ui];
          if (hit) { if (a < 0) a = t; b = t; gap = 0; } else if (a >= 0 && ++gap > FRAME_GAP) flush();
        }
        flush();
      }
    }
    // one line per stroke: drop near-duplicates of a longer one, then
    // join collinear pieces (a frame line broken where art covers it)
    segs.sort((p, q) => q.len - p.len);
    const pos = (g, t) => g.o + g.s * (t - mid);
    const lines = [];
    for (const g of segs) {
      const m = (g.a + g.b) / 2;
      const same = lines.find((h) => Math.abs(h.s - g.s) <= 0.04 && Math.abs(pos(h, m) - pos(g, m)) <= 5 &&
        Math.abs(pos(h, g.a) - pos(g, g.a)) <= 5 && Math.abs(pos(h, g.b) - pos(g, g.b)) <= 5);
      if (same) { same.a = Math.min(same.a, g.a); same.b = Math.max(same.b, g.b); same.total += Math.max(0, g.len - 0); continue; }
      if (lines.length < FRAME_LINES * 4) lines.push({ o: g.o, s: g.s, a: g.a, b: g.b, total: g.len, horizontal, mid });
    }
    lines.sort((p, q) => q.total - p.total);
    return lines.slice(0, FRAME_LINES);
  };
  const hs = sweep(true), vs = sweep(false);
  // the page edge can close a panel that bleeds off it (one side at most)
  hs.push({ o: 0, s: 0, a: 0, b: W - 1, horizontal: true, mid: W / 2, edge: true },
          { o: H - 1, s: 0, a: 0, b: W - 1, horizontal: true, mid: W / 2, edge: true });
  vs.push({ o: 0, s: 0, a: 0, b: H - 1, horizontal: false, mid: H / 2, edge: true },
          { o: W - 1, s: 0, a: 0, b: H - 1, horizontal: false, mid: H / 2, edge: true });

  // running count of line pixels along each line, so a side's coverage
  // is one subtraction
  for (const ln of [...hs, ...vs]) {
    const span = ln.horizontal ? W : H;
    const pre = new Int32Array(span + 1);
    for (let t = 0; t < span; t++) {
      const u = ln.o + ln.s * (t - ln.mid);
      pre[t + 1] = pre[t] + (ln.edge ? 1 : ln.horizontal ? at(t, u) : at(u, t));
    }
    ln.pre = pre;
  }
  const lineCover = (ln, t0, t1) => {
    const span = ln.pre.length - 1;
    const a = Math.max(0, Math.min(span - 1, Math.round(Math.min(t0, t1))));
    const b = Math.max(0, Math.min(span - 1, Math.round(Math.max(t0, t1))));
    return (ln.pre[b + 1] - ln.pre[a]) / (b - a + 1);
  };

  // horizontal h: y = h.o + h.s·(x − h.mid); vertical v: x = v.o + v.s·(y − v.mid)
  const cross = (h, v) => {
    let y = h.o, x = 0;
    for (let k = 0; k < 4; k++) { x = v.o + v.s * (y - v.mid); y = h.o + h.s * (x - h.mid); }
    return [x, y];
  };
  const cover = (p, q) => {
    const n = Math.max(1, Math.round(Math.hypot(q[0] - p[0], q[1] - p[1])));
    let hit = 0;
    for (let k = 0; k <= n; k++) if (at(p[0] + ((q[0] - p[0]) * k) / n, p[1] + ((q[1] - p[1]) * k) / n)) hit++;
    return hit / (n + 1);
  };
  // share of a side with open page just beyond its line (outward normal o)
  const isPaper = (x, y) => {
    const xi = Math.round(x), yi = Math.round(y);
    return xi < 0 || yi < 0 || xi >= W || yi >= H || paper[yi * W + xi] === 1;
  };
  const openOut = (p, q, ox, oy) => {
    const n = Math.max(1, Math.round(Math.hypot(q[0] - p[0], q[1] - p[1]) / 2));
    let ok = 0;
    for (let k = 0; k <= n; k++) {
      const x = p[0] + ((q[0] - p[0]) * k) / n, y = p[1] + ((q[1] - p[1]) * k) / n;
      let d = 1;
      while (d <= 6 && lum[Math.round(y + oy * d) * W + Math.round(x + ox * d)] < LINE_LIGHT &&
             !isPaper(x + ox * d, y + oy * d)) d++;
      let all = true;
      for (let e = d + 1; e <= d + 3 && all; e++) all = isPaper(x + ox * e, y + oy * e);
      if (all) ok++;
    }
    return ok / (n + 1);
  };
  const within = (v, lo, hi) => v >= lo - FRAME_CORNER && v <= hi + FRAME_CORNER;
  // does a gutter band run through the frame (a column or row of its
  // inside nearly all open gutter or blank page — narrow gutters get
  // sealed by the ink dilation, so count blank too)? Then it spans two
  // panels.
  // running counts of blank (open gutter or paper) pixels down each column
  // and along each row
  const colPre = new Uint16Array(W * (H + 1)), rowPre = new Uint16Array(H * (W + 1));
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = y * W + x;
      const b = !geo.label[i] || paper[i] ? 1 : 0;
      colPre[(y + 1) * W + x] = colPre[y * W + x] + b;
      rowPre[y * (W + 1) + x + 1] = rowPre[y * (W + 1) + x] + b;
    }
  }
  const interiorGutter = (pts) => {
    // the frame's inside, approximated by its box inset past the slant
    const xs = pts.map((p) => p[0]).sort((a, b) => a - b), ys = pts.map((p) => p[1]).sort((a, b) => a - b);
    const x0 = Math.max(0, Math.ceil(xs[1]) + 6), x1 = Math.min(W - 1, Math.floor(xs[2]) - 6);
    const y0 = Math.max(0, Math.ceil(ys[1]) + 6), y1 = Math.min(H - 1, Math.floor(ys[2]) - 6);
    if (x1 - x0 < 8 || y1 - y0 < 8) return 1;
    let worst = 0;
    for (let x = x0; x <= x1; x++) {
      worst = Math.max(worst, (colPre[(y1 + 1) * W + x] - colPre[y0 * W + x]) / (y1 - y0 + 1));
    }
    for (let y = y0; y <= y1; y++) {
      worst = Math.max(worst, (rowPre[y * (W + 1) + x1 + 1] - rowPre[y * (W + 1) + x0]) / (x1 - x0 + 1));
    }
    return worst;
  };
  // share of a side whose inner band (past its line) is flooded gutter
  const gutterIn = (p, q, ix, iy) => {
    const n = Math.max(1, Math.round(Math.hypot(q[0] - p[0], q[1] - p[1]) / 3));
    let gut = 0, cnt = 0;
    for (let k = 1; k < n; k++) {
      const x = p[0] + ((q[0] - p[0]) * k) / n, y = p[1] + ((q[1] - p[1]) * k) / n;
      for (const d of [5, 8]) {
        const xi = Math.round(x + ix * d), yi = Math.round(y + iy * d);
        if (xi < 0 || yi < 0 || xi >= W || yi >= H) continue;
        cnt++;
        if (!geo.label[yi * W + xi]) gut++;
      }
    }
    return cnt ? gut / cnt : 0;
  };
  const minSide = FRAME_SIDE_MIN * L;

  const quads = [];
  const seen = new Set(); // frames already judged, by corners rounded to 6 px
  for (const T of hs) {
    for (const B of hs) {
      if (B === T) continue;
      const tY = T.o, bY = B.o;
      if (bY - tY < minSide) continue;
      if (Math.min(T.b, B.b) - Math.max(T.a, B.a) < minSide) continue;
      // left / right candidates meeting both T and B inside their spans
      const sides = [];
      for (const V of vs) {
        const tc = cross(T, V), bc = cross(B, V);
        if (!within(tc[0], T.a, T.b) || !within(bc[0], B.a, B.b)) continue;
        if (Math.min(V.b, bc[1]) - Math.max(V.a, tc[1]) < 0.5 * (bc[1] - tc[1])) continue;
        const vc = lineCover(V, tc[1], bc[1]);
        if (vc < FRAME_WEAK) continue;
        sides.push({ V, tc, bc, vc });
      }
      // the best-drawn few, left to right
      sides.sort((p, q) => q.vc - p.vc);
      sides.length = Math.min(sides.length, FRAME_SIDES);
      sides.sort((p, q) => p.tc[0] - q.tc[0]);
      for (let i = 0; i < sides.length; i++) {
        for (let j = i + 1; j < sides.length; j++) {
          const l = sides[i], r = sides[j];
          if (r.tc[0] - l.tc[0] < minSide || r.bc[0] - l.bc[0] < minSide) continue;
          const pts = [l.tc, r.tc, r.bc, l.bc];
          const edges = [T.edge, r.V.edge, B.edge, l.V.edge];
          if (edges.filter(Boolean).length > 1) continue;
          const cov = [lineCover(T, l.tc[0], r.tc[0]), lineCover(r.V, r.tc[1], r.bc[1]),
                       lineCover(B, l.bc[0], r.bc[0]), lineCover(l.V, l.tc[1], l.bc[1])];
          const sorted = [...cov].sort((p, q) => q - p);
          if (sorted[2] < FRAME_STRONG || sorted[3] < FRAME_WEAK) continue;
          if (cov.filter((v, k) => !edges[k] && v >= FRAME_STRONG).length < 2) continue;
          const key = pts.map(([x, y]) => `${Math.round(x / 6)},${Math.round(y / 6)}`).join(" ");
          if (seen.has(key)) continue;
          seen.add(key);
          // a partly hidden side still meets real corners: the two sides
          // beside it stop there instead of running on past it (an art
          // line across a panel would cut its frame lines mid-way)
          // the page edge doesn't count as facing page: two drawn sides must
          const open = [openOut(l.tc, r.tc, 0, -1), openOut(r.tc, r.bc, 1, 0), openOut(l.bc, r.bc, 0, 1), openOut(l.tc, l.bc, -1, 0)]
            .map((v, k) => (edges[k] ? 0 : v));
          if (open.filter((v) => v >= FRAME_OPEN).length < FRAME_OPEN_SIDES) continue;
          // just inside every drawn side is panel, not the page's open gutter
          // (two stacked panels' borders would otherwise make one frame)
          const ins = [[l.tc, r.tc, 0, 1], [r.tc, r.bc, -1, 0], [l.bc, r.bc, 0, -1], [l.tc, l.bc, 1, 0]];
          if (ins.some(([p, q, ix, iy], k) => !edges[k] && gutterIn(p, q, ix, iy) > FRAME_GUTTER_IN)) continue;
          if (interiorGutter(pts) > FRAME_INTERIOR_GUTTER) continue;
          // A frame is closed: its lines stop at its corners. An art line
          // across a panel makes a "frame" with that panel's own border,
          // which runs on straight past the fake corner. Followed along the
          // side's own detected line, so art drawn across the gap beyond a
          // real corner doesn't count; a gutter between two panels whose
          // lines align is a clean gap.
          // (a small fan of angles around the side: the detected line can be
          // a degree or two off the drawn one)
          const lightAt = (x, y) => {
            const xi = Math.round(x), yi = Math.round(y);
            return xi < 0 || yi < 0 || xi >= W || yi >= H || lum[yi * W + xi] > LINE_LIGHT;
          };
          // (ox, oy): outward from the frame — a border running on has the
          // open gutter just outside it, art drawn across a gap doesn't
          const runsOn = (line, from, dir, ox, oy) => {
            const p0 = line.horizontal ? [from, line.o + line.s * (from - line.mid)] : [line.o + line.s * (from - line.mid), from];
            // (and from up to 2 px either side: the detected line can sit a
            // px or two off the drawn one at the corner)
            for (let off = -2; off <= 2; off++) {
              for (let ds = -FRAME_RUN_FAN; ds <= FRAME_RUN_FAN + 1e-9; ds += FRAME_RUN_FAN / 4) {
                const sl = line.s + ds;
                let gap = 0, ok = true;
                for (let d = 2; d <= FRAME_RUN_ON && ok; d++) {
                  const x = line.horizontal ? p0[0] + dir * d : p0[0] + off + sl * dir * d;
                  const y = line.horizontal ? p0[1] + off + sl * dir * d : p0[1] + dir * d;
                  if (at(x, y) && (lightAt(x + ox * 4, y + oy * 4) || lightAt(x + ox * 5, y + oy * 5))) gap = 0;
                  else if (++gap > 2) ok = false;
                }
                if (ok) return true;
              }
            }
            return false;
          };
          const sideLines = [T, r.V, B, l.V];
          const OUT = [[0, -1], [1, 0], [0, 1], [-1, 0]];
          const ends = [
            [0, l.tc[0], -1], [0, r.tc[0], 1],   // top past TL (left), past TR (right)
            [2, l.bc[0], -1], [2, r.bc[0], 1],   // bottom
            [3, l.tc[1], -1], [3, l.bc[1], 1],   // left past TL (up), past BL (down)
            [1, r.tc[1], -1], [1, r.bc[1], 1]    // right
          ];
          // decided per piece (splitByFrames): it only rules a frame out on
          // a side that bounds the piece — on the side facing the fused art,
          // that art may be drawn right across the gap
          const runs = [false, false, false, false];
          for (const [k, from, dir] of ends) {
            if (!edges[k] && !runs[k] && runsOn(sideLines[k], from, dir, OUT[k][0], OUT[k][1])) runs[k] = true;
          }
          const area = 0.5 * Math.abs(pts.reduce((acc, [x, y], k) => {
            const [x2, y2] = pts[(k + 1) % 4];
            return acc + x * y2 - x2 * y;
          }, 0));
          quads.push({ pts, area, cov, runs });
        }
      }
    }
  }
  // near-identical frames (neighbouring offsets of the same lines): keep one
  quads.sort((p, q) => q.area - p.area);
  const kept = [];
  for (const q of quads) {
    const dup = kept.some((k) => k.pts.every(([x, y], i) => Math.hypot(x - q.pts[i][0], y - q.pts[i][1]) <= 10));
    if (!dup) kept.push(q);
  }
  return kept;
}

// Split piece g by the frames lying in it. Returns the new pieces, or null.
function splitByFrames(geo, g, frames, minPanelPx) {
  const { W, label } = geo;
  const STEP = 3;
  // frames inside this piece, with their area in it
  const cands = [];
  for (const f of frames) {
    const xs = f.pts.map((p) => p[0]), ys = f.pts.map((p) => p[1]);
    // must lie (nearly) within the piece's box to lie in the piece
    const slack = 0.1 * Math.max(...xs) - 0.1 * Math.min(...xs) + 8;
    if (Math.min(...xs) < g.minX - slack || Math.max(...xs) > g.maxX + slack ||
        Math.min(...ys) < g.minY - slack || Math.max(...ys) > g.maxY + slack) continue;
    let solid = 0, mine = 0, total = 0;
    for (let y = Math.max(0, Math.ceil(Math.min(...ys))); y <= Math.min(geo.H - 1, Math.max(...ys)); y += STEP) {
      for (let x = Math.max(0, Math.ceil(Math.min(...xs))); x <= Math.min(W - 1, Math.max(...xs)); x += STEP) {
        if (!inQuad(f.pts, x, y)) continue;
        total++;
        if (!label[y * W + x]) continue; // open page inside the frame
        solid++;
        if (inside(geo, g, x, y)) mine++;
      }
    }
    if (solid < 0.3 * total || mine < FRAME_IN * solid) continue;
    // a frame on the piece's own boundary: past at least two drawn sides
    // the piece ends (page, gutter, a cut). A window or doorway drawn
    // inside a panel has more of the panel beyond every side.
    const cx = xs.reduce((a, v) => a + v, 0) / 4, cy = ys.reduce((a, v) => a + v, 0) / 4;
    let bounding = 0;
    for (let k = 0; k < 4; k++) {
      const [ax, ay] = f.pts[k], [bx, by] = f.pts[(k + 1) % 4];
      const mx = (ax + bx) / 2, my = (ay + by) / 2;
      const len = Math.hypot(bx - ax, by - ay) || 1;
      let nx = -(by - ay) / len, ny = (bx - ax) / len;
      if (nx * (mx - cx) + ny * (my - cy) < 0) { nx = -nx; ny = -ny; } // outward
      const onEdge = [ax, bx].every((v) => v <= 1 || v >= W - 2) || [ay, by].every((v) => v <= 1 || v >= geo.H - 2);
      if (onEdge) continue;
      let out = 0, n = 0;
      for (let t = 0.1; t <= 0.9; t += 0.05) {
        const px = ax + (bx - ax) * t, py = ay + (by - ay) * t;
        for (const d of [7, 10]) {
          const qx = Math.round(px + nx * d), qy = Math.round(py + ny * d);
          n++;
          if (qx < 0 || qy < 0 || qx >= W || qy >= geo.H || !inside(geo, g, qx, qy)) out++;
        }
      }
      if (out >= FRAME_BOUND * n) {
        bounding++;
        // its line runs on past a corner: it's that panel's own border,
        // and the "frame" an art line across the panel
        if (f.runs[k]) { bounding = -9; break; }
      }
    }
    if (bounding < 2) continue;
    const area = mine * STEP * STEP;
    if (area < minPanelPx || area >= FRAME_ALL * g.area) continue;
    cands.push({ f, area });
  }
  if (!cands.length) return null;
  // largest first, no overlaps
  cands.sort((p, q) => q.area - p.area);
  const chosen = [];
  for (const c of cands) {
    const clash = chosen.some((k) => k.f.pts.some(([x, y]) => inQuad(c.f.pts, x, y)) || c.f.pts.some(([x, y]) => inQuad(k.f.pts, x, y)));
    if (!clash) chosen.push(c);
  }
  const rest = g.area - chosen.reduce((a, c) => a + c.area, 0);
  if (chosen.length === 1 && rest < Math.max(minPanelPx, FRAME_REST * g.area)) return null;

  // grown past the frame line and the region's dilation halo, so no
  // border slivers stay with the rest
  const grow = (pts, d) => {
    const cx = pts.reduce((a, p) => a + p[0], 0) / 4, cy = pts.reduce((a, p) => a + p[1], 0) / 4;
    return pts.map(([x, y]) => [x + Math.sign(x - cx) * d, y + Math.sign(y - cy) * d]);
  };
  const pad = geo.halo + 6;
  const base = { id: g.id, cuts: g.cuts, rects: g.rects, quads: g.quads || [] };
  const parts = chosen.map((c) => measure(geo, { ...base, quads: [...base.quads, { pts: grow(c.f.pts, pad), keep: true }] }, g));
  const restPiece = measure(geo, { ...base, quads: [...base.quads, ...chosen.map((c) => ({ pts: grow(c.f.pts, pad), keep: false }))] }, g);
  restPiece.frameRest = true;
  // one frame with only a sliver beside it: the frame is the whole panel
  if (chosen.length === 1 && restPiece.area < Math.max(minPanelPx, FRAME_REST * g.area)) return null;
  // several: a sliver left over is just border debris
  if (restPiece.area < minPanelPx) restPiece.bleed = true;
  const all = [...parts, restPiece].filter((p) => p.area > 0);
  for (const p of all) p.escapes = (g.escapes || []).filter((e) => inside(geo, p, e.seedX, e.seedY));
  return all;
}

// Leftover art beside frames, cut apart by gutter lines through open page
// (a borderless panel above a row of boxes gets sliced per column): join
// rests that touch along a shared edge back into one panel.
function mergeFrameRests(shapes, pageW, pageH, scale) {
  const list = [...shapes];
  const others = shapes.filter((s) => !s.frameRest && s.area >= PANEL_MIN_AREA);
  const gapMax = 0.02 * Math.max(pageW, pageH);
  const touch = (a, b) => {
    const gx = Math.max(a.x, b.x) - Math.min(a.x + a.w, b.x + b.w);
    const gy = Math.max(a.y, b.y) - Math.min(a.y + a.h, b.y + b.h);
    const ovY = -gy, ovX = -gx;
    return (gx <= gapMax && ovY >= 0.3 * Math.min(a.h, b.h)) || (gy <= gapMax && ovX >= 0.3 * Math.min(a.w, b.w));
  };
  for (let changed = true; changed; ) {
    changed = false;
    outer: for (let i = 0; i < list.length; i++) {
      for (let j = i + 1; j < list.length; j++) {
        const a = list[i], b = list[j];
        if (!a.frameRest || !b.frameRest || !touch(a, b)) continue;
        const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
        const rows = new Map(a.rows || []);
        for (const [ry, [lo, hi]] of b.rows || []) {
          const r = rows.get(ry);
          rows.set(ry, r ? [Math.min(r[0], lo), Math.max(r[1], hi)] : [lo, hi]);
        }
        const joined = {
          ...a, x, y,
          w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y,
          area: a.area + b.area,
          hull: convexHull([...a.hull, ...b.hull].flat()),
          escapes: [...(a.escapes || []), ...(b.escapes || [])],
          rows
        };
        // not if the joined art would take in part of a real panel
        if (others.some((o) => coveredShare(o, joined, scale) > 0.2)) continue;
        list[i] = joined;
        list.splice(j, 1);
        changed = true;
        break outer;
      }
    }
  }
  return list;
}

// ── Ruled rectangles ───────────────────────────────────────────────────
//
// Borderless art (open backgrounds, bubbles, a building drawn straight
// on the page) can fuse with a neighbouring ruled panel through speed
// lines or overlapping shapes, leaving no gutter line to cut along. A
// ruled panel still announces itself: four straight ink edges. Find the
// largest rectangle inside the piece whose sides are ≥ RULE_COVER ink,
// and peel it off when the rest is a panel-sized area of its own.

const RULE_MIN_RUN = 0.3;   // border candidates: ink run ≥ this share of the span
const RULE_COVER = 0.85;    // each rectangle side must be this much ink
const RULE_CANDS = 8;
const RULE_OUTSIDE = 0.6;   // ≥ 3 sides need paper just outside on this much of their length
const RECT_FILL = 0.85;     // pieces filling ≥ this much of their box are panels already

function peelRuledRect(geo, g) {
  const { W, H, inkRaw } = geo;
  const bw = g.maxX - g.minX + 1, bh = g.maxY - g.minY + 1;
  if (bw < 40 || bh < 40) return null;
  // a single ruled panel already fills its box — nothing to peel
  if (g.area >= RECT_FILL * bw * bh) return null;
  const { paper } = geo;
  const ink = (x, y) => x >= 0 && y >= 0 && x < W && y < H && inkRaw[y * W + x] === 1;
  const inkNear = (x, y, vertical) =>
    vertical ? ink(x - 1, y) || ink(x, y) || ink(x + 1, y) : ink(x, y - 1) || ink(x, y) || ink(x, y + 1);

  // candidate border lines: longest ink run (gaps ≤ 2px), one per cluster
  const candidates = (count, span, runAt) => {
    const runs = [];
    for (let i = 0; i < count; i++) {
      let best = 0, cur = 0, gap = 0;
      for (let j = 0; j < span; j++) {
        if (runAt(i, j)) { cur += gap + 1; gap = 0; if (cur > best) best = cur; }
        else if (++gap > 2) { cur = 0; gap = 0; }
      }
      runs.push(best);
    }
    const picks = [];
    const order = runs.map((v, i) => [v, i]).filter(([v]) => v >= RULE_MIN_RUN * span).sort((a, b) => b[0] - a[0]);
    for (const [, i] of order) {
      if (picks.every((p) => Math.abs(p - i) > 4)) picks.push(i);
      if (picks.length >= RULE_CANDS) break;
    }
    return picks.sort((a, b) => a - b);
  };
  const xs = candidates(bw, bh, (i, j) => ink(g.minX + i, g.minY + j)).map((i) => g.minX + i);
  const ys = candidates(bh, bw, (i, j) => ink(g.minX + j, g.minY + i)).map((i) => g.minY + i);
  if (xs.length < 2 || ys.length < 2) return null;

  const cover = (fixed, a, b, vertical) => {
    let hit = 0;
    for (let k = a; k <= b; k++) if (vertical ? inkNear(fixed, k, true) : inkNear(k, fixed, false)) hit++;
    return hit / (b - a + 1);
  };
  // Share of a side with paper just beyond it. The candidate column /
  // row can sit on either edge of a thick border line, so first step
  // outward past the border's own ink (≤ 5px), then require 2–4px of
  // paper beyond that.
  const isPaper = (x, y) => x < 0 || y < 0 || x >= W || y >= H || paper[y * W + x] === 1;
  const outside = (fixed, a, b, vertical, dir) => {
    let ok = 0;
    for (let k = a; k <= b; k++) {
      const at = (d) => (vertical ? [fixed + dir * d, k] : [k, fixed + dir * d]);
      let d = 1;
      while (d <= 5 && ink(...at(d))) d++;
      let all = true;
      for (let e = d + 1; e <= d + 3 && all; e++) all = isPaper(...at(e));
      if (all) ok++;
    }
    return ok / (b - a + 1);
  };
  let best = null;
  for (let li = 0; li < xs.length; li++) for (let ri = li + 1; ri < xs.length; ri++) {
    const l = xs[li], r = xs[ri];
    if (r - l < 0.15 * bw) continue;
    for (let ti = 0; ti < ys.length; ti++) for (let bi = ti + 1; bi < ys.length; bi++) {
      const t = ys[ti], b = ys[bi];
      if (b - t < 0.15 * bh) continue;
      const area = (r - l) * (b - t);
      if (best && area <= best.area) continue;
      if (cover(l, t, b, true) < RULE_COVER || cover(r, t, b, true) < RULE_COVER) continue;
      if (cover(t, l, r, false) < RULE_COVER || cover(b, l, r, false) < RULE_COVER) continue;
      // the side the extra art is fused onto won't face paper; the
      // other three must (a rectangle drawn inside art has none)
      const open = [outside(l, t, b, true, -1), outside(r, t, b, true, 1),
                    outside(t, l, r, false, -1), outside(b, l, r, false, 1)];
      if (open.filter((v) => v >= RULE_OUTSIDE).length < 3) continue;
      best = { l, r, t, b, area };
    }
  }
  if (!best) return null;

  // Grow each side outward across the full thickness of its border line
  // (and the dilation halo every region carries) so no border pixels are
  // left on the remainder — they'd stretch its box across the panel.
  const rect = { l: best.l, r: best.r, t: best.t, b: best.b };
  for (let k = 0; k < 6 && cover(rect.l - 1, rect.t, rect.b, true) >= RULE_COVER; k++) rect.l--;
  for (let k = 0; k < 6 && cover(rect.r + 1, rect.t, rect.b, true) >= RULE_COVER; k++) rect.r++;
  for (let k = 0; k < 6 && cover(rect.t - 1, rect.l, rect.r, false) >= RULE_COVER; k++) rect.t--;
  for (let k = 0; k < 6 && cover(rect.b + 1, rect.l, rect.r, false) >= RULE_COVER; k++) rect.b++;
  // + the antialiased edge and the region's dilation halo
  const pad = 1 + geo.halo;
  rect.l -= pad; rect.r += pad; rect.t -= pad; rect.b += pad;
  const inner = measure(geo, { id: g.id, cuts: g.cuts, rects: [...(g.rects || []), { ...rect, keep: true }] }, g);
  const outer = measure(geo, { id: g.id, cuts: g.cuts, rects: [...(g.rects || []), { ...rect, keep: false }] }, g);
  const minRest = Math.max(SPLIT_MIN_AREA * W * H, 0.12 * g.area);
  if (inner.area < SPLIT_MIN_AREA * W * H || outer.area < minRest) return null;
  // the art left beside a ruled box is like art beside a frame
  outer.frameRest = true;
  return [inner, outer];
}

// ── Bleed trim ─────────────────────────────────────────────────────────
//
// A panel whose border is drawn complete on all four sides can still
// flood together with a neighbour's tone or gradient that bleeds right
// up to its line (a scene fading from the black page to white beside a
// boxed panel). Nothing crosses a complete border, so whatever lies
// outside it only touches it: trim the panel to the box and mark the
// rest as bleed (background, not a panel).
//
// "Ink" can't find the border here — on black-gutter pages anything not
// black is ink, so a gray gradient looks fully inked. A border is a
// THIN dark line with light art right beside it; a gradient or a dense
// dark area has no light within a few px, and screentone dots break up
// any long run.

const LINE_DARK = 110;      // a border pixel is darker than this...
const LINE_LIGHT = 150;     // ...with a pixel lighter than this close by
const LINE_NEAR = 8;        // px either side to look for that light
const TRIM_COVER = 0.95;    // all four sides this complete = nothing crosses
const TRIM_KEEP = 0.6;      // the box must hold this much of the piece
const TRIM_MIN = 0.005;     // ...and the bleed outside it ≥ this much of the page
const TRIM_MAX_REST = 0.35; // ...but at most this much of the box (else it's art)

function trimToRuledBox(geo, g) {
  const { W, H, lum } = geo;
  const bw = g.maxX - g.minX + 1, bh = g.maxY - g.minY + 1;
  if (bw < 40 || bh < 40) return null;
  const L = (x, y) => (x < 0 || y < 0 || x >= W || y >= H ? 255 : lum[y * W + x]);
  // a thin dark line through (x, y), running vertically or horizontally
  const line = (x, y, vertical) => {
    if (L(x, y) >= LINE_DARK) return false;
    for (let d = 2; d <= LINE_NEAR; d++) {
      if (vertical ? L(x - d, y) > LINE_LIGHT || L(x + d, y) > LINE_LIGHT
                   : L(x, y - d) > LINE_LIGHT || L(x, y + d) > LINE_LIGHT) return true;
    }
    return false;
  };
  const near = (x, y, vertical) =>
    vertical ? line(x - 1, y, true) || line(x, y, true) || line(x + 1, y, true)
             : line(x, y - 1, false) || line(x, y, false) || line(x, y + 1, false);
  const cover = (fixed, a, b, vertical) => {
    let hit = 0;
    for (let k = a; k <= b; k++) if (vertical ? near(fixed, k, true) : near(k, fixed, false)) hit++;
    return hit / (b - a + 1);
  };
  const candidates = (count, span, at) => {
    const runs = [];
    for (let i = 0; i < count; i++) {
      let best = 0, cur = 0, gap = 0;
      for (let j = 0; j < span; j++) {
        if (at(i, j)) { cur += gap + 1; gap = 0; if (cur > best) best = cur; }
        else if (++gap > 2) { cur = 0; gap = 0; }
      }
      runs.push(best);
    }
    const picks = [];
    for (const [, i] of runs.map((v, i) => [v, i]).filter(([v]) => v >= 0.5 * span).sort((p, q) => q[0] - p[0])) {
      if (picks.every((p) => Math.abs(p - i) > 4)) picks.push(i);
      if (picks.length >= RULE_CANDS) break;
    }
    return picks.sort((p, q) => p - q);
  };
  // the piece's own edges are candidates too: a side facing the gutter
  // needs no drawn line (see `closed`)
  const withEdges = (list, lo, hi) =>
    [lo, ...list.filter((v) => v - lo > 4 && hi - v > 4), hi];
  const xs = withEdges(candidates(bw, bh, (i, j) => line(g.minX + i, g.minY + j, true)).map((i) => g.minX + i), g.minX, g.maxX);
  const ys = withEdges(candidates(bh, bw, (i, j) => line(g.minX + j, g.minY + i, false)).map((i) => g.minY + i), g.minY, g.maxY);

  // A side is closed when nothing of the piece lies just beyond it (it
  // faces the gutter), or when it's a complete thin line.
  const beyond = (fixed, a, b, vertical, dir) => {
    let out = 0;
    for (let k = a; k <= b; k++) {
      const x = vertical ? fixed + dir * 3 : k, y = vertical ? k : fixed + dir * 3;
      if (x < 0 || y < 0 || x >= W || y >= H || !inside(geo, g, x, y)) out++;
    }
    return out / (b - a + 1);
  };
  const closed = (fixed, a, b, vertical, dir) =>
    beyond(fixed, a, b, vertical, dir) >= TRIM_COVER || cover(fixed, a, b, vertical) >= TRIM_COVER;

  let box = null;
  for (let li = 0; li < xs.length; li++) for (let ri = li + 1; ri < xs.length; ri++) {
    const l = xs[li], r = xs[ri];
    if (r - l < 0.3 * bw) continue;
    for (let ti = 0; ti < ys.length; ti++) for (let bi = ti + 1; bi < ys.length; bi++) {
      const t = ys[ti], b = ys[bi];
      if (b - t < 0.3 * bh) continue;
      const area = (r - l) * (b - t);
      if (!closed(l, t, b, true, -1) || !closed(r, t, b, true, 1)) continue;
      if (!closed(t, l, r, false, -1) || !closed(b, l, r, false, 1)) continue;
      // at least one side must be a drawn line inside the piece — the line
      // the bleed stops at (the piece's own box passes trivially otherwise)
      // prefer the box with the most such lines (each one bleed stops
      // at), then the bigger box
      const drawn = [[l, t, b, true, g.minX], [r, t, b, true, g.maxX], [t, l, r, false, g.minY], [b, l, r, false, g.maxY]]
        .filter(([f, a, bb, v, edge]) => Math.abs(f - edge) > 4 && cover(f, a, bb, v) >= TRIM_COVER).length;
      if (!drawn) continue;
      if (box && (drawn < box.drawn || (drawn === box.drawn && area <= box.area))) continue;
      box = { l, r, t, b, area, drawn };
    }
  }
  if (!box) return null;

  const pad = 2 + geo.halo; // border thickness + dilation halo
  const rect = { l: box.l - pad, r: box.r + pad, t: box.t - pad, b: box.b + pad };
  const inner = measure(geo, { id: g.id, cuts: g.cuts, escapes: g.escapes, rects: [...(g.rects || []), { ...rect, keep: true }] }, g);
  const outer = measure(geo, { id: g.id, cuts: g.cuts, rects: [...(g.rects || []), { ...rect, keep: false }] }, g);
  if (inner.area < TRIM_KEEP * g.area || outer.area < Math.max(TRIM_MIN * W * H, 0.05 * g.area)) return null;
  // bleed is a sliver of tone at the panel's edge; a leftover this big
  // is art (a strip of sea under a sky, the rest of a room past a door
  // frame) that a straight line in the drawing only looked like a border
  if (outer.area > TRIM_MAX_REST * inner.area) return null;
  return [inner, { ...outer, bleed: true }];
}

// ── Sliver merge ───────────────────────────────────────────────────────
//
// A small piece that touches or overlaps a bigger panel along most of
// its width (or height) is that panel's art cut off — dark hair leaking
// the gutter flood on black-gutter pages, a hat poking over a border —
// so fold it back in rather than calling it a panel.

const SLIVER_MAX = 0.015;  // pieces under this share of the page
const SLIVER_TOUCH = 4;    // px (natural) gap still counted as touching

const NESTED = 0.9;  // share of the smaller shape inside the bigger one
const NEST_GRID = 12;

function insideHull(hull, x, y) {
  let sign = 0;
  for (let i = 0; i < hull.length; i++) {
    const [ax, ay] = hull[i], [bx, by] = hull[(i + 1) % hull.length];
    const c = (bx - ax) * (y - ay) - (by - ay) * (x - ax);
    if (c === 0) continue;
    if (sign === 0) sign = Math.sign(c);
    else if (Math.sign(c) !== sign) return false;
  }
  return true;
}

// Sampled share of p's shape inside q's row extents, or inside q's
// bounding box spanned row-wise (for a joined shape whose rows span both
// parts plus the gap between them).
function coveredShare(p, q, scale) {
  let total = 0, hit = 0;
  for (let i = 0; i < NEST_GRID; i++) {
    for (let j = 0; j < NEST_GRID; j++) {
      const x = p.x + ((i + 0.5) / NEST_GRID) * p.w, y = p.y + ((j + 0.5) / NEST_GRID) * p.h;
      if (!insideHull(p.hull, x, y)) continue;
      total++;
      if (insideHull(q.hull, x, y)) hit++;
    }
  }
  return total ? hit / total : 0;
}

// Sampled share of p's shape lying inside q's real shape (its row
// extents — not q's convex hull, which for an L-shaped panel covers the
// panels in its crook).
function within(p, q, scale) {
  if (!q.rows) return false;
  let total = 0, hit = 0;
  for (let i = 0; i < NEST_GRID; i++) {
    for (let j = 0; j < NEST_GRID; j++) {
      const x = p.x + ((i + 0.5) / NEST_GRID) * p.w, y = p.y + ((j + 0.5) / NEST_GRID) * p.h;
      if (!insideHull(p.hull, x, y)) continue;
      total++;
      const r = q.rows.get(Math.floor(y * scale));
      if (r && x * scale >= r[0] && x * scale <= r[1]) hit++;
    }
  }
  return total > 0 && hit >= total * NESTED;
}

// A speech balloon floating on open page (a borderless panel's dialogue
// drifting off the art) floods as a region of its own: it's mostly one
// blank blob, not box-shaped. It reads with the nearest panel — joined
// to it as a balloon escape, so that panel's view takes it in.
const FLOAT_GAP = 0.06; // of the page's long side

function attachFloating(panels, span) {
  const hosts = panels.filter((p) => !p.floating);
  const out = [];
  for (const p of panels) {
    if (!p.floating) { out.push(p); continue; }
    let host = null, best = FLOAT_GAP * span;
    for (const q of hosts) {
      const d = hullGap(p.hull, q.hull);
      if (d <= best) { best = d; host = q; }
    }
    if (!host) { out.push(p); continue; }
    host.escapes.push({ sure: true, balloon: true, hull: p.hull });
    const v = host.view, x0 = Math.min(v.x, p.x), y0 = Math.min(v.y, p.y);
    host.view = { x: x0, y: y0, w: Math.max(v.x + v.w, p.x + p.w) - x0, h: Math.max(v.y + v.h, p.y + p.h) - y0 };
  }
  return out;
}

// Gap between two convex hulls (0 when they overlap).
function hullGap(a, b) {
  if (a.some(([x, y]) => insideHull(b, x, y)) || b.some(([x, y]) => insideHull(a, x, y))) return 0;
  const seg = ([px, py], [ax, ay], [bx, by]) => {
    const dx = bx - ax, dy = by - ay, l = dx * dx + dy * dy;
    const t = l ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / l)) : 0;
    return Math.hypot(px - ax - t * dx, py - ay - t * dy);
  };
  let d = Infinity;
  for (const [p, q] of [[a, b], [b, a]]) {
    for (const pt of p) for (let i = 0; i < q.length; i++) d = Math.min(d, seg(pt, q[i], q[(i + 1) % q.length]));
  }
  return d;
}

function mergeSlivers(panels) {
  const list = [...panels];
  for (let changed = true; changed; ) {
    changed = false;
    for (const s of [...list].sort((a, b) => a.area - b.area)) {
      if (s.area >= SLIVER_MAX) break;
      const host = list.find((p) => p !== s && p.area > s.area * 2 && touches(s, p));
      if (!host) continue;
      const pts = [...host.hull, ...s.hull].flatMap(([x, y]) => [x, y]);
      const x = Math.min(host.x, s.x), y = Math.min(host.y, s.y);
      Object.assign(host, {
        x, y,
        w: Math.max(host.x + host.w, s.x + s.w) - x,
        h: Math.max(host.y + host.h, s.y + s.h) - y,
        area: host.area + s.area,
        hull: convexHull(pts)
      });
      for (const [ry, [lo, hi]] of s.rows || []) {
        const r = host.rows?.get(ry);
        if (r) { r[0] = Math.min(r[0], lo); r[1] = Math.max(r[1], hi); } else host.rows?.set(ry, [lo, hi]);
      }
      list.splice(list.indexOf(s), 1);
      changed = true;
      break;
    }
  }
  return list;
}

function touches(s, p) {
  const xOver = Math.min(s.x + s.w, p.x + p.w) - Math.max(s.x, p.x);
  const yOver = Math.min(s.y + s.h, p.y + p.h) - Math.max(s.y, p.y);
  return (xOver >= 0.7 * s.w && yOver >= -SLIVER_TOUCH) || (yOver >= 0.7 * s.h && xOver >= -SLIVER_TOUCH);
}

function dilate(src, W, H, r) {
  const tmp = new Uint8Array(src.length);
  const out = new Uint8Array(src.length);
  for (let y = 0; y < H; y++) {
    const row = y * W;
    for (let x = 0; x < W; x++) {
      let v = 0;
      for (let k = Math.max(0, x - r), e = Math.min(W - 1, x + r); k <= e && !v; k++) v = src[row + k];
      tmp[row + x] = v;
    }
  }
  for (let x = 0; x < W; x++) {
    for (let y = 0; y < H; y++) {
      let v = 0;
      for (let k = Math.max(0, y - r), e = Math.min(H - 1, y + r); k <= e && !v; k++) v = tmp[k * W + x];
      out[y * W + x] = v;
    }
  }
  return out;
}

// Monotone-chain convex hull over a flat [x0, y0, x1, y1, ...] list.
function convexHull(flat) {
  const pts = [];
  for (let i = 0; i < flat.length; i += 2) pts.push([flat[i], flat[i + 1]]);
  if (pts.length < 3) return pts;
  pts.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const cross = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  const lower = [], upper = [];
  for (const p of pts) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], p) <= 0) lower.pop();
    lower.push(p);
  }
  for (let i = pts.length - 1; i >= 0; i--) {
    const p = pts[i];
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], p) <= 0) upper.pop();
    upper.push(p);
  }
  upper.pop(); lower.pop();
  return lower.concat(upper);
}

// Reading order: recursive XY grouping. Split the panels into rows
// (merged vertical extents); several rows → read them top → bottom.
// One row → split it into columns (merged horizontal extents) and read
// those right → left for RTL manga (left → right otherwise), recursing
// into each — so two panels stacked in a column read top before bottom
// even when a tall neighbour spans both. Extents only merge on a real
// overlap (≥ GROUP_OVERLAP of the smaller), so slanted gutters whose
// boxes graze each other still separate.
const GROUP_OVERLAP = 0.35;

function orderPanels(panels, direction) {
  if (panels.length <= 1) return panels;
  const rows = group(panels, (p) => [p.y, p.y + p.h]);
  if (rows.length > 1) return rows.flatMap((r) => orderPanels(r, direction));
  const cols = group(panels, (p) => [p.x, p.x + p.w]);
  if (cols.length > 1) {
    if (direction !== "ltr") cols.reverse();
    return cols.flatMap((c) => orderPanels(c, direction));
  }
  // overlapping both ways — fall back to top-down, then reading side
  const rtl = direction !== "ltr";
  return [...panels].sort((a, b) => a.y - b.y || (rtl ? b.x - a.x : a.x - b.x));
}

// Group by interval overlap along one axis; groups come back in
// ascending order of that axis.
function group(panels, span) {
  const sorted = [...panels].sort((a, b) => span(a)[0] - span(b)[0]);
  const groups = [];
  for (const p of sorted) {
    const [a, b] = span(p);
    const g = groups[groups.length - 1];
    if (g && Math.min(g.end, b) - Math.max(g.start, a) >= GROUP_OVERLAP * Math.min(b - a, g.minLen)) {
      g.items.push(p); g.end = Math.max(g.end, b); g.minLen = Math.min(g.minLen, b - a);
    } else {
      groups.push({ start: a, end: b, minLen: b - a, items: [p] });
    }
  }
  return groups.map((g) => g.items);
}

