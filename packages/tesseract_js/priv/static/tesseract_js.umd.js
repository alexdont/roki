/*!
 * tesseract_js — Phoenix-friendly wrapper for tesseract.js
 * MIT License
 *
 * UMD build. Attaches to window.TesseractJs in browsers.
 * Source: assets/js/src/{index,ocr_worker}.js
 */
(function (root, factory) {
  if (typeof define === "function" && define.amd) {
    define([], factory);
  } else if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.TesseractJs = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var cachedWorker = null;
  var pendingWorker = null;

  function defaults() {
    return (typeof window !== "undefined" && window.__tesseractJs) || {};
  }

  function ensureTesseract(opts) {
    if (typeof window === "undefined") {
      return Promise.reject(new Error("tesseract_js requires a browser environment"));
    }
    if (window.Tesseract) return Promise.resolve(window.Tesseract);

    var src = opts.tesseractPath || defaults().tesseractPath;
    if (!src) {
      return Promise.reject(
        new Error(
          "tesseract.js is not loaded and no tesseractPath was provided. " +
            "Either include the <TesseractJs.Component.script /> HEEx component, " +
            "or pass {tesseractPath: '...'} when calling getOcrWorker()."
        )
      );
    }

    return new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = src;
      s.onload = function () {
        if (window.Tesseract) resolve(window.Tesseract);
        else reject(new Error("tesseract.js loaded but window.Tesseract is missing"));
      };
      s.onerror = function () {
        reject(new Error("failed to load tesseract.js from " + src));
      };
      document.head.appendChild(s);
    });
  }

  function getOcrWorker(opts) {
    opts = opts || {};
    if (cachedWorker) return Promise.resolve(cachedWorker);
    if (pendingWorker) return pendingWorker;

    var d = defaults();
    var cfg = {};
    for (var k in d) cfg[k] = d[k];
    for (var k2 in opts) cfg[k2] = opts[k2];

    pendingWorker = (function () {
      return ensureTesseract(cfg).then(function (Tesseract) {
        return Tesseract.createWorker(cfg.lang || "eng", cfg.oem == null ? 1 : cfg.oem, {
          workerPath: cfg.workerPath,
          corePath: cfg.corePath,
          langPath: cfg.langPath
        }).then(function (w) {
          cachedWorker = w;
          return w;
        });
      });
    })();

    pendingWorker.catch(function () {
      pendingWorker = null;
    });

    return pendingWorker;
  }

  function recognize(imageLike, opts) {
    return getOcrWorker(opts).then(function (worker) {
      return worker.recognize(imageLike);
    });
  }

  function resetWorker() {
    var w = cachedWorker;
    cachedWorker = null;
    pendingWorker = null;
    if (w && typeof w.terminate === "function") {
      try {
        return Promise.resolve(w.terminate()).catch(function () {});
      } catch (_e) {
        return Promise.resolve();
      }
    }
    return Promise.resolve();
  }

  return {
    getOcrWorker: getOcrWorker,
    recognize: recognize,
    resetWorker: resetWorker
  };
});
