"use strict";

// Runs one Nuvio provider in a child process that Roki opened for exactly one call.
//
// The process is started with Node's permission model, code generation disabled, no
// filesystem or child-process permission and an empty environment. The provider sees a
// small context: module/exports, a curated `require`, fetch, timers and a few text/URL
// helpers. It never sees process, the environment, the filesystem, raw network modules or
// the host's network stack. The only third-party modules available are the two bundled in
// `vendor/nuvio-vendor.js`; the only built-ins available are side-effect-free.
//
// `fetch` is a guard, not just a binding: HTTPS only, no private/loopback/link-local
// addresses, a redirect hop limit and a response-size ceiling.

const vm = require("vm");
const dns = require("dns");
const net = require("net");
const path = require("path");

const SAFE_BUILTINS = new Set([
  "assert",
  "buffer",
  "crypto",
  "events",
  "querystring",
  "stream",
  "string_decoder",
  "timers",
  "url",
  "util"
]);

let vendor = null;

function vendorModule() {
  if (!vendor) vendor = require(path.join(__dirname, "vendor", "nuvio-vendor.js"));
  return vendor;
}

// A provider's `require` is not Node's. It can return the two reviewed bundles or a
// side-effect-free built-in; everything else throws before it can be used.
function safeRequire(name) {
  if (name === "cheerio" || name === "cheerio-without-node-native") {
    return vendorModule().cheerio;
  }
  if (name === "crypto-js") return vendorModule().CryptoJS;

  const base = typeof name === "string" && name.startsWith("node:") ? name.slice(5) : name;
  if (SAFE_BUILTINS.has(base)) return require(name);
  throw new Error("module not allowed: " + String(name));
}

const MAX_BYTES = 8 * 1024 * 1024;
const MAX_REDIRECTS = 4;
const MAX_REQUESTS = 100;
let requests = 0;
const BLOCKED_HOST =
  /^(localhost|.*\.local|.*\.internal|0\.0\.0\.0|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|\[::1\]|\[fc|\[fd|\[fe80|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/i;

function privateAddress(address) {
  if (net.isIPv4(address)) {
    const [a, b] = address.split(".").map(Number);
    return (
      a === 0 ||
      a === 10 ||
      a === 127 ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) ||
      (a === 100 && b >= 64 && b <= 127)
    );
  }
  if (net.isIPv6(address)) {
    const h = address.toLowerCase();
    return h === "::1" || h.startsWith("fc") || h.startsWith("fd") || h.startsWith("fe80");
  }
  return false;
}

async function publicUrl(raw) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new Error("invalid url");
  }
  if (u.protocol !== "https:") throw new Error("only https is allowed");
  if (BLOCKED_HOST.test(u.hostname)) throw new Error("private address blocked");

  // A public-looking name can resolve into the server's own network. Resolve it here,
  // in the host runner (not in the provider context) before the request leaves.
  const addrs = await dns.promises.lookup(u.hostname, { all: true }).catch(() => []);
  if (addrs.length === 0) throw new Error("host could not be resolved");
  if (addrs.some((entry) => privateAddress(entry.address))) {
    throw new Error("private address blocked");
  }

  return u.toString();
}

async function safeFetch(input, init = {}) {
  let url = typeof input === "string" ? input : input && input.url;
  if (!url) throw new Error("invalid request");
  const opts = { ...init };
  let redirects = 0;

  for (;;) {
    if (++requests > MAX_REQUESTS) throw new Error("too many requests");
    url = await publicUrl(url);
    const res = await fetch(url, { ...opts, redirect: "manual" });
    if ([301, 302, 303, 307, 308].includes(res.status)) {
      const loc = res.headers.get("location");
      if (!loc || ++redirects > MAX_REDIRECTS) throw new Error("too many redirects");
      url = new URL(loc, url).toString();
      continue;
    }
    const len = Number(res.headers.get("content-length") || 0);
    if (len > MAX_BYTES) throw new Error("response too large");
    return res;
  }
}

// One JSON request, one line. A trailing newline is the end-of-request marker: the port
// keeps stdin open, so waiting for EOF would make every call look like a hang.
// Node's stdout is a pipe here. `process.exit` immediately after a write can truncate
// anything past the pipe buffer, so wait for the write callback and keep a short fallback.
function finish(payload) {
  const text = JSON.stringify(payload);
  process.stdout.write(text, () => process.exit(0));
  setTimeout(() => process.exit(0), 1000).unref();
}

function readInput() {
  return new Promise((resolve, reject) => {
    let data = "";
    let done = false;
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      if (done) return;
      data += chunk;
      const nl = data.indexOf("\n");
      if (nl !== -1) {
        done = true;
        resolve(data.slice(0, nl));
      }
    });
    process.stdin.on("end", () => {
      if (!done) {
        done = true;
        resolve(data);
      }
    });
    process.stdin.on("error", reject);
  });
}

function makeConsole(logs) {
  const push = (level) => (...args) => {
    if (logs.length >= 50) return;
    try {
      logs.push([level, args.map(String).join(" ").slice(0, 500)]);
    } catch {
      /* ignore */
    }
  };
  return {
    log: push("log"),
    info: push("info"),
    warn: push("warn"),
    error: push("error"),
    debug: push("debug")
  };
}

(async () => {
  let input;
  try {
    input = JSON.parse(await readInput());
  } catch {
    finish({ ok: false, error: "invalid runner input", logs: [] });
    return;
  }

  if (typeof input.source !== "string") {
    finish({ ok: false, error: "missing source", logs: [] });
    return;
  }

  const logs = [];
  const sandbox = {
    module: { exports: {} },
    exports: {},
    require: safeRequire,
    console: makeConsole(logs),
    fetch: safeFetch,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    queueMicrotask,
    URL,
    URLSearchParams,
    TextEncoder,
    TextDecoder,
    atob,
    btoa,
    AbortController,
    Response,
    Request,
    Headers,
    SCRAPER_SETTINGS: input.settings && typeof input.settings === "object" ? input.settings : {}
  };
  sandbox.globalThis = sandbox;
  sandbox.global = sandbox;
  sandbox.window = sandbox;
  sandbox.self = sandbox;

  const ctx = vm.createContext(sandbox, { name: "nuvio-provider" });

  try {
    vm.runInContext(input.source, ctx, { filename: "provider.js", timeout: 5000 });
    const exported = sandbox.module.exports || {};
    const settingsMode = input.mode === "settings";
    const fn = settingsMode ? exported.onSettings : exported.getStreams;

    if (typeof fn !== "function") {
      throw new Error(settingsMode ? "onSettings is not exported" : "getStreams is not exported");
    }

    const result = settingsMode ? await fn() : await fn(...(input.args || []));
    if (settingsMode) {
      if (!Array.isArray(result)) throw new Error("onSettings did not return an array");
      finish({ ok: true, settings: result, logs });
    } else {
      if (!Array.isArray(result)) throw new Error("getStreams did not return an array");
      finish({ ok: true, streams: result, logs });
    }
  } catch (e) {
    finish({ ok: false, error: String((e && e.message) || e), logs });
  }
})();
