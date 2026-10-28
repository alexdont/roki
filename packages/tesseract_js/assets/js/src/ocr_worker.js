// Singleton-cached tesseract.js worker. Idempotent: repeat calls return the
// same Promise<Worker>. The first call loads the upstream tesseract.js if it
// isn't already on window, then awaits `createWorker`.

let cachedWorker = null;
let pendingWorker = null;

function defaults() {
  return (typeof window !== "undefined" && window.__tesseractJs) || {};
}

function ensureTesseract(opts) {
  if (typeof window === "undefined") {
    return Promise.reject(new Error("tesseract_js requires a browser environment"));
  }
  if (window.Tesseract) return Promise.resolve(window.Tesseract);

  const src = opts.tesseractPath || defaults().tesseractPath;
  if (!src) {
    return Promise.reject(
      new Error(
        "tesseract.js is not loaded and no tesseractPath was provided. " +
          "Either include the <TesseractJs.Component.script /> HEEx component, " +
          "or pass {tesseractPath: '...'} when calling getOcrWorker()."
      )
    );
  }

  return new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = src;
    s.onload = () => (window.Tesseract ? resolve(window.Tesseract) : reject(new Error("tesseract.js loaded but window.Tesseract is missing")));
    s.onerror = () => reject(new Error("failed to load tesseract.js from " + src));
    document.head.appendChild(s);
  });
}

export function getOcrWorker(opts = {}) {
  if (cachedWorker) return Promise.resolve(cachedWorker);
  if (pendingWorker) return pendingWorker;

  const cfg = { ...defaults(), ...opts };

  pendingWorker = (async () => {
    const Tesseract = await ensureTesseract(cfg);
    cachedWorker = await Tesseract.createWorker(cfg.lang || "eng", cfg.oem ?? 1, {
      workerPath: cfg.workerPath,
      corePath: cfg.corePath,
      langPath: cfg.langPath
    });
    return cachedWorker;
  })();

  // Don't keep the rejected promise cached.
  pendingWorker.catch(() => {
    pendingWorker = null;
  });

  return pendingWorker;
}

export async function recognize(imageLike, opts = {}) {
  const worker = await getOcrWorker(opts);
  return worker.recognize(imageLike);
}

export async function resetWorker() {
  const w = cachedWorker;
  cachedWorker = null;
  pendingWorker = null;
  if (w && typeof w.terminate === "function") {
    try {
      await w.terminate();
    } catch (_) {
      // ignore
    }
  }
}
