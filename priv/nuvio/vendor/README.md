# Nuvio provider vendor bundle

`nuvio-vendor.js` is a single CommonJS bundle, built from:

- `cheerio-without-node-native@1.0.0-rc.2` (MIT)
- `crypto-js@4.2.0` (MIT)

and their transitive dependencies (all permissively licensed; the full graph is pinned in
`package-lock.json`, and license comments are kept at the end of the bundle by esbuild).

Why this exact Cheerio fork: the providers target `cheerio-without-node-native`'s API. The
maintained `cheerio/slim` build parses `4khdhub`/`moviebox` correctly but breaks
`moviesdrive` and `uhdmovies`, so the fork is pinned for compatibility. npm marks this fork
deprecated; it is executed only inside the Nuvio sandbox, with no filesystem, process,
environment, or raw network access. Replacing it should be done by testing the providers
above, not by changing the name alone.

## Rebuilding

```bash
npm install --no-audit --no-fund
cat > entry.js <<'EOF'
const cheerio = require("cheerio-without-node-native");
const CryptoJS = require("crypto-js");
module.exports = { cheerio, CryptoJS };
EOF
esbuild entry.js --bundle --platform=node --format=cjs --target=node22 \
  --legal-comments=eof --outfile=nuvio-vendor.js
```

The sandbox runner maps `require("cheerio")` and
`require("cheerio-without-node-native")` to this Cheerio object, and
`require("crypto-js")` to CryptoJS. No other third-party module is available.
