# Changelog

## 0.1.11

### Fixed

* **Snapping under a notch or a translucent status bar.** The shell is pulled
  up past the safe-area inset so a chapter can run to the top of the screen,
  which makes the container taller than the screen and starts it off-screen.
  The landing offset was measured from the container's top, so every snap
  landed a status bar too high — the first thing a snap put on screen was
  behind the clock — and the probe that decides whether a landing sits in a
  gutter read a row that far out with it. The offset is now measured from the
  bottom of the status bar: 5.5% of what can be seen, plus twice the inset —
  one to get past the off-screen part of the container, one to clear the bar.
  Unchanged
  wherever there is no inset, which is every browser tab and every app laid
  out below the status bar rather than under it.

## 0.1.10 (2026-09-25)

* Backward snapping reworked to one rule: the nearest panel start
  meaningfully above the probe, where "meaningfully" is a quarter
  viewport. Within that range of a panel start the reader is
  considered AT it (touch tap-jitter and settle tolerance mean a
  settled position is never pixel-exact), so a back-tap goes to the
  panel BEFORE it. The old two-branch code got stuck oscillating
  between a panel start and the gutter above it: from a gutter it
  scanned FORWARD ("align the panel below"), turning back-taps into
  little downward hops, and its phase walk always skipped the
  current panel's top.
* Backward snaps never half-step. A back-jump's distance spans
  panel + gutter, so on gutter-heavy strips nearly every back-tap
  measured as "long panel" and stranded the reader mid-spacing.
  Reading backward lands on panel starts, full stop.
* Debug: the strip logs a `strip_boot` beacon (build stamp + UA) on
  every load and a `snap_move` record per snap (position before,
  computed target, settled position, probe image/row, settle stats)
  to the host's `debug_log_url` — fire-and-forget, a few hundred
  bytes per tap. Diagnosing "the reader misbehaves on my phone"
  no longer requires the user to toggle anything. Build stamp:
  `manhwa-bf1-2026-09-25` (also printed to the console on boot).


## 0.1.9 (2026-07-17)

* Read checkmark in the progress pill: once the host confirms a
  chapter counts as read, the bottom-center indicator shows a green ✓
  over the chapter's last 5% — and latches for that chapter, so
  scrolling back keeps showing it was read to completion. Opt-in for
  hosts — `save_progress` may now return
  `{:ok, %{chapter_read: boolean}}` and the progress endpoint echoes
  it to the reader; stores that keep returning `:ok` see no change.
  A `false` verdict also clears a stale mark (rereads restart their
  time bar). Configurable: `config :manhwa, read_check_percent: 95`
  (display gate, `0` = show on confirmation) and
  `read_check_mark: "✓"` (any short string/emoji).
* The pill's "% left" now measures from the BOTTOM of the viewport —
  only content below the fold counts as left to read; what's on
  screen is already seen. (It previously measured at the progress
  anchor, so a full screen of visible content counted as unread.)
  Progress saves and resume keep their existing anchor — only the
  display changed. The read checkmark's display gate rides the same
  measure, so it appears once less than 5% remains below the fold.

## 0.1.8 (2026-07-16)

* Revert the experimental custom rAF snap-motion driver (briefly
  committed as 0.1.8, never published): it felt great on desktop but
  stayed sluggish on iOS. The strip is back to 0.1.7's proven
  native-smooth-scroll motion with settle verification, unchanged
  from 0.1.5 except for the rate-limited chapter-boundary reading-
  time flush (the chapter-counting fix). The experiments live on the
  `snap-motion-rework` branch for a future attempt.

## 0.1.7 (2026-07-16)

* Fix scroll/snap jank introduced by 0.1.6's boundary flush: image
  dominance can oscillate at a chapter boundary (the snap motion's
  settle corrections nudge the viewport back and forth), and the
  flush fired a synchronous fetch inside the scroll handler on every
  flip — a burst of requests mid-animation. Boundary flushes are now
  rate-limited to one per crossing window and the fetch is deferred
  off the scroll frame.

## 0.1.6 (2026-07-15)

* Reading-time fix: crossing a chapter boundary in the infinite
  scroll now flushes accumulated time against the *outgoing* chapter
  first. Previously, finishing a chapter without a ≥500ms scroll
  pause on its last pages meant those pages were never reported —
  the host app's near-end/chapter-count logic never fired and the
  reading time was attributed to the next chapter. Scrolling down
  out of a chapter pins the report to its last page (the end was
  read through); scrolling back up flushes at the departure position.

## 0.1.5 (2026-07-14)

* Docs: the Store's page-dimensions contract now points implementors
  at the [`dims`](https://hex.pm/packages/dims) package (README wiring
  example + `fetch_pages` callback docs) — probe URLs' width × height
  cheaply instead of writing your own prober.

## 0.1.4 (2026-07-14)

* Half-stepping now keys on the exact condition — the current panel
  extending past the bottom of the viewport (unread content below the
  fold) — instead of the distance-to-next-target proxy, which stopped
  firing on narrow layouts (page padding, small windows) and skipped
  panel bottoms with trailing text bubbles. If the fold instead cuts a
  *different* panel (gutter between), the snap goes to that panel's
  start, revealing it from the top.
* The scan debounce (`min_gutter_width`, a source-px setting) now
  converts to the local rendering scale — real gutters no longer
  vanish from targeting when images render below source scale, which
  had fused panels and their text bubbles into one jump.
* The free-scroll realign special case is gone: the fold rule is
  position-exact, so arbitrary positions get the right behavior
  naturally (half-step iff the current panel crosses the fold,
  otherwise full snap to the nearest target).

## 0.1.3 (2026-07-14)

* Panel snap rebuilt to legacy fidelity: gutter detection now analyzes
  every source row at native resolution (legacy-style sparse column
  sampling, sliced canvas — same speed class as before), the landing
  rule is legacy's "first non-gutter row" (the dense-content
  adjustment is now opt-in via `smart_landing`), the phase-2 noise
  skip shrank from 2000 to 300 source-px and shares one content
  predicate (dark OR sustained-variance — pale art can no longer be
  skipped as noise) with band merging, and snaps now await detection
  for the whole scan range instead of silently degrading to a raw
  viewport jump on a cold cache.
* Gutters must match the page background, not just be flat: each image
  estimates its background from band colors (one vote per band, so
  recurring gutters out-vote any single flat art region), with
  near-white flat bands always accepted. Blurred/uniform panel
  openings no longer classify as gutters, and black-page flashback
  chapters keep their dark gutters.
* Predictive snap queue: the next 7 forward snap targets are
  precomputed from the resting position (and rebuilt on scroll/settle/
  config change), stored as layout-shift-proof anchors — a tap
  consumes a ready target with zero scan latency, and the build
  doubles as image prewarm for the panels ahead. The queue flushes
  synchronously on any manual scroll so stale chains can never skip
  targets.
* Free scrolling breaks snap alignment: the first tap afterwards goes
  straight to the nearest panel start (no long-panel half-step from an
  arbitrary position); alignment restores on any completed landing.
* Resume restore now re-anchors the saved fraction at the viewport
  center — matching how progress saves measure it — instead of the
  top, which had every "continue" landing half a viewport below where
  the user stopped.
* Snap probe offset returned to the legacy 5.5% of viewport height
  (was 10%).

## 0.1.2 (2026-07-14)

* The mouse-gesture button (bottom-right) now shows a 4-directional
  move icon instead of a down arrow, matching the OS auto-scroll
  affordance it provides.
* Middle-click (scroll-wheel button) anywhere in the reader now
  toggles mouse-gesture mode — the same gesture as OS auto-scroll.
  Middle-clicks on links/controls keep their native behavior.
* Fix: the nav's prev/next chapter arrows now retarget to the dominant
  chapter's neighbours as the strip auto-appends chapters — they were
  server-rendered against the landing chapter and went stale (the
  chapter label already synced). The next-arrow hides past the last
  known chapter instead of keeping a stale target.

## 0.1.1 (2026-07-13)

* Fix: the strip page assumed the host's user struct has a `.uuid`
  field (rendered into a dead `data-user-uuid` attribute), crashing
  the render for hosts with differently-shaped users. The Store
  contract treats the user as opaque — now the templates do too.

## 0.1.0 (2026-07-13)

Initial extraction from the Greenoak reader:

* `Manhwa.Router.manhwa_reader/2` — mounts the reader page + full API
  surface (chapter images, settings PUTs, progress, image proxy, marks,
  GIF search, debug log) under one prefix.
* `Manhwa.Store` behaviour — the host persistence contract (chapters,
  pages with dimension hints, reader state, settings, progress, proxy
  authorization, page overrides).
* `Manhwa.Annotations` / `Manhwa.GifProvider` optional adapters;
  pluggable `:etcher_host` LiveView (drawing-only default included).
* Strip reader on fresco_strip: panel-snap with per-manga tuning,
  scroll speeds, auto-reader (+ optional OCR smart delay via
  `:extra_head`), tap-zone presets, infinite next-chapter append,
  cursor-hide gesture mode, snap debugger.
