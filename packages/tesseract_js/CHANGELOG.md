# Changelog

## 0.1.0 — Initial release

- `TesseractJs.Models` — curated registry of 20 common languages, sha256-ready (values nullable in v0.1).
- CDN mode (default, via jsDelivr) and local mode driven by the same registry.
- Two quality tiers: `:standard` (full LSTM+legacy combined) and `:best` (LSTM-only, ~3M/lang).
- `mix tesseract_js.install_assets` — copies the bundled JS (tesseract.min.js, worker.min.js, the wrapper UMD) into the host's `priv/static/assets/vendor/tesseract/`.
- `mix tesseract_js.download` — downloads core WASM + traineddata files into the same dir for local mode.
- HEEx components `<.preload />` and `<.script />` for one-line Phoenix integration.
- UMD JS bundle attaches to `window.TesseractJs` (`getOcrWorker`, `recognize`, `resetWorker`).
- Pinned to tesseract.js-core 5.1.1, tessdata 4.0.0.

### Known limitations
- `:fast` tier (`tessdata_fast`) is not supported — it requires uncompressed `.traineddata` from a different source. Slated for v0.2.
- Checksums in the curated registry are `nil`; the download task warns when it skips verification. Real sha256 values land in 0.1.1.
