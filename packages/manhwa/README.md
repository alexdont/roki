# Manhwa

Batteries-included **long-strip comic reader** for Phoenix — webtoons, manhwa,
manhua, anything that reads by scrolling.

Mounts its own routes via a router macro, persists through a small Store
behaviour, and ships the full reader UI on top of
[fresco_strip](https://hex.pm/packages/fresco_strip): pixel-space panel-snap
(gutter detection), per-manga snap tuning, scroll speeds, auto-reader with
optional OCR-adaptive delay, tap-zone presets, infinite next-chapter loading,
progress persistence (page + fraction + reading time), a same-origin image
proxy with per-source headers, and an optional annotation layer via
[etcher](https://hex.pm/packages/etcher).

**Reading paged comics?** That's the sibling package —
[`manga`](https://hex.pm/packages/manga) — a page/spread reader built on
fresco's pan-zoom canvas (RTL/LTR, double-page spreads, page overrides).

---

## Install

```elixir
def deps do
  [
    {:manhwa, "~> 0.1"}
  ]
end
```

## Wire it up

**1. Routes** — one macro call mounts the reader page and its whole API
surface (chapter images, settings, progress, image proxy, marks, GIFs)
under the same prefix:

```elixir
# router.ex
import Manhwa.Router

scope "/" do
  pipe_through [:browser, :require_auth]
  manhwa_reader "/reader/manga"          # → /reader/manga/:source/:slug/:chapter
end
```

Options: `series_segments: 1 | 2` (default 2 — a series is `/:source/:slug`;
with 1 it's a single `/:series` slug).

**2. Store** — implement `Manhwa.Store` (the persistence contract: chapter
lists, page URLs, per-series reader state, settings, progress, proxy
authorization) and point config at it:

```elixir
config :manhwa,
  store: MyApp.ReaderStore,
  current_user: {MyAppWeb.ReaderGlue, :current_user},   # (conn) -> user
  series_url: {MyAppWeb.ReaderGlue, :series_url}        # (series) -> details page path
```

The reader never fetches content itself — your store supplies the page
URLs, ideally **with dimensions** (`fetch_pages` returning
`%{url, width, height}`): correct dims up-front mean stable layout,
scroll positions, and snap targets before a single image loads. If
your source only gives you URLs, [`dims`](https://hex.pm/packages/dims)
does exactly this job — it probes width × height from a ~128 KB HTTP
Range fetch, with batch/sampling/median-backfill strategies sized for
chapter-length lists:

```elixir
def fetch_pages(_user, series, chapter, opts) do
  urls = MySource.chapter_image_urls(series, chapter)
  {:ok, if(opts[:dims] == :precise, do: Dims.probe_all(urls), else: Dims.probe_sampled(urls))}
end
```

**3. JS** — import fresco_strip's hooks in `assets/js/app.js` (plus etcher's
if you use annotations):

```js
import "../../deps/fresco_strip/priv/static/fresco_strip.js"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { ...(window.FrescoHooks || {}), ...(window.EtcherHooks || {}) }
})
```

**4. CSS** — the templates use Tailwind + daisyUI classes (daisyUI v5 theme
tokens). Add the package to your Tailwind v4 sources:

```css
@source "../../deps/manhwa";
```

## Optional adapters

Everything below lights up extra affordances; without them the reader
renders fully, minus those buttons:

| Config key | Contract | Powers |
|---|---|---|
| `annotations:` | `Manhwa.Annotations` | Etcher shape persistence, marks API, shape comments |
| `gif_provider:` | `Manhwa.GifProvider` | GIF picker in the annotation composer |
| `etcher_host:` | a LiveView module | The embedded Etcher layer host (default: `Manhwa.EtcherHost`, drawing-only; bring your own for comment threads) |
| `extra_head:` | `{mod, fun}` component | e.g. an OCR runtime for the smart auto-reader |
| `legacy_url:` | `{mod, fun}` | "Legacy reader" link in settings |
| `debug_log_path:` | file path | On-device telemetry sink (snap-verdict labeling) |

## License

MIT
