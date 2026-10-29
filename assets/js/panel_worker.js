// Web Worker for panel detection (see panel_detect.js). Built as its
// own esbuild entry → /assets/js/panel_worker.js; panel_overlay.js
// posts full-size page pixels here so detection never stalls swiping.
import { detectFromImage } from "./panel_detect";

self.onmessage = ({ data: { id, px, nw, nh, direction } }) => {
  try {
    self.postMessage({ id, result: detectFromImage(px, nw, nh, direction) });
  } catch (err) {
    self.postMessage({ id, error: String(err && err.message || err) });
  }
};
