# tesseract_js

Phoenix-friendly wrapper for [tesseract.js](https://github.com/naptha/tesseract.js).
Run OCR in the browser — manga, document scanning, receipt parsing, anything
with text in an image — without writing tesseract.js boilerplate.

- Drop-in HEEx components for one-line Phoenix integration.
- One model registry serves both **CDN mode** (default, zero-setup) and
  **local mode** (one Mix task downloads everything).
- Singleton-cached worker — call `getOcrWorker()` as many times as you want.

## Installation

```elixir
def deps do
  [
    {:tesseract_js, "~> 0.1"}
  ]
end
```

```bash
mix deps.get
mix tesseract_js.install_assets    # copies the bundled JS into priv/static/
```

In your layout:

```heex
<%!-- root.html.heex --%>
<TesseractJs.Component.preload />
<TesseractJs.Component.script />
```

In your JS:

```js
const { getOcrWorker, recognize } = window.TesseractJs;
const { data } = await recognize(canvasOrImg);
console.log(data.text);
```

That's it. CDN mode (jsDelivr) is the default — no setup needed.

## Configuration

```elixir
# config/config.exs
config :tesseract_js,
  lang: "eng",                # default language
  source: :cdn,               # :cdn (default) or :local
  tessdata_repo: :standard,   # :standard or :best
  core_variant: :simd_lstm    # :simd_lstm | :simd | :basic
```

## Languages

Pick any tesseract language code, or combine with `+`:

```elixir
config :tesseract_js, lang: "eng+jpn_vert"
```

A curated registry is shipped for help text + checksums (`mix tesseract_js.download --list`):

| code | name | code | name |
|------|------|------|------|
| `eng` | English | `nld` | Dutch |
| `jpn` | Japanese | `pol` | Polish |
| `jpn_vert` | Japanese (vertical, manga-friendly) | `tur` | Turkish |
| `chi_sim` | Chinese (simplified) | `vie` | Vietnamese |
| `chi_tra` | Chinese (traditional) | `tha` | Thai |
| `kor` | Korean | `ukr` | Ukrainian |
| `fra` | French | `ara` | Arabic |
| `deu` | German | `hin` | Hindi |
| `spa` | Spanish | `rus` | Russian |
| `ita` | Italian | `por` | Portuguese |

Any code outside the curated list (e.g. `swe`, `nor`, `dan`, `heb`) still works at runtime —
it just falls through to the URL template without checksum verification. Full list of
language codes: [tesseract-ocr/tessdata · LANGUAGES](https://github.com/tesseract-ocr/tessdata/blob/main/README.md#the-list-of-languages-available-in-this-repository).

## Quality tiers (`tessdata_repo`)

| tier | size | accuracy | notes |
|------|------|----------|-------|
| `:standard` (default) | ~11 MB/lang gzipped | full LSTM+legacy combined | |
| `:best` | ~3 MB/lang gzipped | LSTM-only (the `_best_int` jsDelivr variant) | smaller and faster to download, similar accuracy for most langs |

> The `:fast` tier from `tesseract-ocr/tessdata_fast` requires uncompressed
> `.traineddata` files served from a different source. Slated for v0.2.

## Local mode

Switch off jsDelivr — useful in production, restricted networks, or offline:

```bash
mix tesseract_js.download eng jpn
# core + two langs into priv/static/assets/vendor/tesseract/
```

Then in `config.exs`:

```elixir
config :tesseract_js, source: :local
```

Task options:

```bash
mix tesseract_js.download --tier best eng jpn  # smaller LSTM-only model
mix tesseract_js.download --core-only          # just the WASM core
mix tesseract_js.download --list               # print the registry
mix tesseract_js.download --force              # re-download
```

## CDN URLs & manual downloads

The package builds these URLs from `TesseractJs.Models`. Use the same URLs to
download files manually (curl, wget, browser, mirror) if the Mix task can't
reach the network from where you're deploying.

### Pinned versions (v0.1.0)

| component | version | source |
|-----------|---------|--------|
| `tesseract.js-core` (WASM runtime) | `5.1.1` | [npm](https://www.npmjs.com/package/tesseract.js-core) |
| `tessdata` (language models) | `4.0.0` | [@tesseract.js-data/* on npm](https://www.npmjs.com/org/tesseract.js-data) |

### Core WASM (one variant per app)

```bash
# SIMD + LSTM (default, fastest on modern CPUs — ~3.8 MB)
curl -O https://cdn.jsdelivr.net/npm/tesseract.js-core@5.1.1/tesseract-core-simd-lstm.wasm.js

# SIMD only
curl -O https://cdn.jsdelivr.net/npm/tesseract.js-core@5.1.1/tesseract-core-simd.wasm.js

# Basic (no SIMD — fallback for very old browsers / restricted environments)
curl -O https://cdn.jsdelivr.net/npm/tesseract.js-core@5.1.1/tesseract-core.wasm.js
```

### Language models — `:standard` tier (full LSTM+legacy, ~11 MB/lang gzipped)

URL template: `https://cdn.jsdelivr.net/npm/@tesseract.js-data/<LANG>@1.0.0/4.0.0/<LANG>.traineddata.gz`

```bash
# English
curl -O https://cdn.jsdelivr.net/npm/@tesseract.js-data/eng@1.0.0/4.0.0/eng.traineddata.gz

# Japanese
curl -O https://cdn.jsdelivr.net/npm/@tesseract.js-data/jpn@1.0.0/4.0.0/jpn.traineddata.gz

# Japanese (vertical, manga-friendly)
curl -O https://cdn.jsdelivr.net/npm/@tesseract.js-data/jpn_vert@1.0.0/4.0.0/jpn_vert.traineddata.gz

# Korean
curl -O https://cdn.jsdelivr.net/npm/@tesseract.js-data/kor@1.0.0/4.0.0/kor.traineddata.gz

# Substitute any lang code from the registry above (or any tesseract code)
curl -O https://cdn.jsdelivr.net/npm/@tesseract.js-data/<LANG>@1.0.0/4.0.0/<LANG>.traineddata.gz
```

### Language models — `:best` tier (LSTM-only, ~3 MB/lang gzipped)

URL template: `https://cdn.jsdelivr.net/npm/@tesseract.js-data/<LANG>@1.0.0/4.0.0_best_int/<LANG>.traineddata.gz`

```bash
# English (best, ~3 MB)
curl -O https://cdn.jsdelivr.net/npm/@tesseract.js-data/eng@1.0.0/4.0.0_best_int/eng.traineddata.gz

# Japanese (best)
curl -O https://cdn.jsdelivr.net/npm/@tesseract.js-data/jpn@1.0.0/4.0.0_best_int/jpn.traineddata.gz
```

### Where to put them for `:local` mode

Drop everything into your Phoenix app's `priv/static/assets/vendor/tesseract/`:

```
priv/static/assets/vendor/tesseract/
├── tesseract.min.js                      ← installed by `mix tesseract_js.install_assets`
├── worker.min.js                         ← installed by `mix tesseract_js.install_assets`
├── tesseract_js.umd.js                   ← installed by `mix tesseract_js.install_assets`
├── tesseract-core-simd-lstm.wasm.js      ← curl OR `mix tesseract_js.download --core-only`
├── eng.traineddata.gz                    ← curl OR `mix tesseract_js.download eng`
└── jpn_vert.traineddata.gz               ← curl OR `mix tesseract_js.download jpn_vert`
```

Then set `config :tesseract_js, source: :local`.

### Generating any URL programmatically

```elixir
iex> TesseractJs.Models.cdn_url("eng")
"https://cdn.jsdelivr.net/npm/@tesseract.js-data/eng@1.0.0/4.0.0/eng.traineddata.gz"

iex> TesseractJs.Models.cdn_url("jpn_vert", :best)
"https://cdn.jsdelivr.net/npm/@tesseract.js-data/jpn_vert@1.0.0/4.0.0_best_int/jpn_vert.traineddata.gz"

iex> TesseractJs.Models.core_cdn_url(:simd_lstm)
"https://cdn.jsdelivr.net/npm/tesseract.js-core@5.1.1/tesseract-core-simd-lstm.wasm.js"
```

## JS API

```js
window.TesseractJs.getOcrWorker(opts?)   // Promise<Worker>; singleton
window.TesseractJs.recognize(imageLike, opts?)
window.TesseractJs.resetWorker()         // terminate + clear singleton
```

`imageLike` is anything tesseract.js's own `recognize()` accepts: canvas, img,
blob, URL, ImageData. `opts` overrides the inline defaults set by `<.script />`.

## How it loads

| File | How it gets there |
|------|-------------------|
| `tesseract.min.js`, `worker.min.js`, `tesseract_js.umd.js` | shipped in the package — copied into your `priv/static/` by `mix tesseract_js.install_assets` |
| `tesseract-core-simd-lstm.wasm.js` | jsDelivr (CDN mode) or `mix tesseract_js.download` (local mode) |
| `<lang>.traineddata.gz` | jsDelivr (CDN mode) or `mix tesseract_js.download <langs>` (local mode) |

## Tasks

| task | what it does |
|------|---------------|
| `mix tesseract_js.install_assets` | copies the bundled JS into your `priv/static/`. Run once after install, again after upgrading the package |
| `mix tesseract_js.download` | downloads core WASM + traineddata for local mode |
| `mix tesseract_js.download --list` | prints the curated language registry |

## License

MIT.
