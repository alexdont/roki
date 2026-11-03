# Nuvio compatibility

Roki has three source collections that are configured independently:

| Collection | Configured by | Module |
|---|---|---|
| Original | a Real-Debrid or TorBox account | `Roki.Laev`, `Roki.Watch.Resolver` |
| PenguPlay | a PenguPlay addon install link | `Roki.Pengu` |
| Nuvio | a set of providers, four on by default, switched per account | `Roki.Nuvio` |

None of them replaces another. `Roki.Sources` reports all three and the sources page, account
menu, and `play_from` setting can choose any one that is configured.

## Where providers come from

`Roki.Nuvio.Registry` fetches

```
https://raw.githubusercontent.com/D3adlyRocket/All-in-One-Nuvio/refs/heads/main/manifest.json
```

(cached for an hour; `NUVIO_MANIFEST_URL` overrides it). A snapshot is committed at
`priv/nuvio/manifest.json` and is used only when the live manifest cannot be fetched; the
result records whether it came from `:live` or `:snapshot`.

The manifest lists 66 entries. Each entry has an id, display name, description, version,
`supportedTypes`, `filename`, optional `hasSettings` / `limited` / format / language fields.
`filename` must be a relative `providers/*.js`; absolute URLs, traversal, and other extensions
are rejected. The source URL is resolved against the manifest's own directory on
`raw.githubusercontent.com`, never against an arbitrary host.

## Provider contract

The providers in this repository are CommonJS bundles. The observed export shapes are:

```js
module.exports = { getStreams }
module.exports = { getStreams, onSettings }
// a few older bundles: module.exports = __provider
```

`getStreams(tmdbId, mediaType, season, episode)` returns an array of objects shaped roughly
like a Stremio stream:

```js
{
  name, title, description, quality, size, language,
  url,                         // https, m3u8 or a file
  headers,                     // request headers, sometimes under behaviorHints.proxyHeaders.request
  behaviorHints: { filename, proxyHeaders },
  subtitles: [{ url, lang }]
}
```

Roki normalises this into the same stream shape `Roki.Pengu` already uses: `id`, `name`,
`provider`, `quality`, `language`, `size`, `codec`, `label`, `url`, `kind` (`:hls` or `:file`),
`headers`, `filename`, `subtitles`. Only public `https://` URLs are accepted. Magnets, `http://`,
private/loopback addresses, and entries without a URL are dropped. Names are stripped of the
zero-width/bidi sorting tags some providers put in them.

`onSettings()` is called in the sandbox, not in the app process. Its `header`, `select`,
`toggle`, `text`, `password`, and `number` fields are normalised for the Settings page. The
manifest's `hasSettings` flag is not trusted: a provider that has no `onSettings` export simply
has no options. Saved options are passed to the provider as `globalThis.SCRAPER_SETTINGS`.

## Eligibility and isolation

A provider runs only if all of these are true:

1. it is on for the account: one of the defaults below that the account has not switched
   off, or one the account switched on in Settings (a toggle per provider);
2. it is among the first 18 that are on (`Roki.Nuvio.max_providers/0`): the account's own,
   most recently switched on first, then the defaults. They run six at a time with 45 s
   each, so a search is at most three rounds. Settings shows how many are on and marks the
   ones past the limit "not asked";
3. the downloaded source passed `Roki.Nuvio.Validator`:
   - UTF-8, under 2 MB, exports `getStreams`;
   - every `require` is a **literal** and only names `cheerio`,
     `cheerio-without-node-native`, `crypto-js`, or a side-effect-free built-in (`assert`,
     `buffer`, `crypto`, `events`, `querystring`, `stream`, `string_decoder`, `timers`, `url`,
     `util`, with optional `node:` prefix);
   - no dynamic `require`, `child_process`, `worker_threads`, filesystem, `eval`,
     `new Function`, dynamic `import`, WebAssembly, plain `http`, or DOM storage/API access.
4. the sandbox starts.

`Roki.Nuvio.Sandbox` runs one provider in a fresh Node process:

- started through `env -i`, so no application environment or secrets are inherited;
- Node's permission model on, with only the runner file readable and no child-process,
  worker, or write permission;
- `--disallow-code-generation-from-strings`, so `Function`-constructor escapes cannot build
  code;
- a context containing only `module`/`exports`, a curated `require`, `console`, timers,
  URL/text helpers, and a guarded `fetch`; the `require` can return only the vendored Cheerio
  and CryptoJS objects or the safe built-ins above;
- `fetch` is HTTPS-only, resolves DNS and blocks private/loopback/link-local results, validates
  each redirect hop, caps response size, and caps the number of requests per call;
- stdout is capped and the process is killed at the deadline (45 seconds for a search,
  8 seconds for settings introspection).

Obfuscated bundles are common in this repository. They are accepted if they pass the static
checks, but marked `obfuscated` in the provider result so the interface says that isolation,
not a human reading of intent, is what contains them. `cheerio-without-node-native` and
`crypto-js` are bundled into `priv/nuvio/vendor/nuvio-vendor.js` (the providers target that
Cheerio fork's API; `cheerio/slim` was tested and breaks `moviesdrive`/`uhdmovies`). The fork
is deprecated upstream and is pinned deliberately; it runs only inside the sandbox. Other
third-party modules and raw `http`/`https`/`net`/`fs` are still rejected rather than shimmed.

## Playback

A Nuvio stream never reuses a debrid path. Files go through the signed Nuvio relay
(`/relay/nuvio?u=&t=`), which carries the provider's request headers and checks public
addresses. HLS goes through `/nuvio/hls?u=&t=`, which fetches the playlist, rewrites every
playlist/key/init/segment URI to a signed URL on this server, and leaves DRM untouched. The
player, resume, history, subtitles, and fallback path are the existing `WatchLive` ones.
A stream that is encrypted with a DRM scheme Roki cannot obtain a licence for will fail to
play; it is not decrypted or bypassed. `Cookie` and `Authorization` headers are not put into
signed playback URLs (they would be visible in browser history and logs); a provider whose
stream requires one of those will be listed but will not play. The verified providers above
need only `Referer`, `Origin` and `User-Agent`.

## Default providers

Every account has these on without visiting Settings (`Roki.Nuvio.Settings.defaults/0`), so
an account with no debrid key or PenguPlay link can still press Play. They were chosen by a
live probe on 2026-11-02 against The Matrix, Oppenheimer, Breaking Bad 1x1 and The Last of
Us 2x1. Each found all four titles in under ten seconds, and a ranged GET of the stream
returned real media (an HLS playlist or an MP4), not a web page:

| Provider | What it gives |
|---|---|
| `playimdb` | English original audio, 1080p HLS, three mirrors |
| `vidrock` | 720p–1080p HLS from two servers |
| `movix` | dual-audio (English/French) HLS |
| `moviebox` | MP4 in several audio languages, **Russian** among them, plus Hindi and the original |

`moviebox` is the Russian option. The two manifest entries that list `ru` do not work:
`goated` returned nothing for any title and has no options, and `gramcinema` needs a cookie
token.

Settings stores the account's own choices in `enabled` and the defaults it switched off in
`disabled`, so a default added later reaches every account, including ones that saved
settings before. An account that switches every provider off has no Nuvio collection, and
the sources page offers to connect one.

An account that has not chosen a "Play from" collection uses the first one available in the
order torrent → Nuvio → PenguPlay (`Roki.Sources.pick/2`). Debrid accounts stay on torrents;
any other account starts on Nuvio, even when it has a PenguPlay link lent to it.

## Verified providers

Probed against The Matrix (TMDB 603, movie) and Breaking Bad S1E1 (TMDB 1396, tv) on
2026-11-02. Sites change; this is a snapshot, not a guarantee. 53 of the 66 manifest entries
pass the current validator; 13 are blocked for the capabilities listed below.

| Provider | Movie | TV | Notes |
|---|---:|---:|---|
| `cinemacity` | 1 | 1 | direct HLS |
| `dahmermovies` | 5 (earlier run) | 5 | site was intermittent on the last movie run |
| `dahmermovies-tv` | 5 | 5 | direct HLS |
| `desiflix` | 2 | 3 | direct streams |
| `movix` | 1 | 1 | direct HLS |
| `playimdb` | 3 | 3 | HLS with Referer/Origin/User-Agent |
| `purstream` | 1 | 1 | HLS with Referer/User-Agent |
| `vidrock` | 2 | 1 | file URL |
| `netmirror` | 4 | 3 | works but takes ~41 s; within the 45 s budget |
| `4khdhub` | 16 | 8 | Cheerio; HubCloud links (**HTML pages, not media**, on 2026-11-02) |
| `moviesdrive` | 6 | 6 | Cheerio |
| `reanime` | 4 | 2 | Cheerio |
| `uhdmovies` | 5 | 3 | Cheerio (**HTML pages, not media**, on 2026-11-02) |
| `moviebox` | 6 | 6 | CryptoJS |

`Roki.NuvioLiveTest` uses the first eight as an external test (the ordinary suite runs with
`config :roki, nuvio_offline: true`: the committed manifest snapshot, no provider source
fetched, nothing sent to GitHub):

```bash
NUVIO_LIVE=1 mix test test/roki/nuvio_live_test.exs --include external
```

## Validated but not operational for the probe titles

These providers passed validation and ran, but returned no playable stream for the two probe
titles, or only returned entries that the normaliser must drop:

`anikototv`, `animetsu`, `Cineby`, `cinefreak`, `ctgmovies`, `dooflix`, `einthusan`,
`goated`, `gramcinema`, `hdghartv`, `hindmoviez`, `kurage`, `moonflix`, `movies4u`,
`movieshunt`, `nakios`, `persianstremio`, `vidfast`, `vidlink`, `vidlove`, `vidsrc`, `xpass`,
`zinkmovies`, `animeworld`, `kisskh`, `onlykdrama`, `anidb`, `anizone`, `fibwatch`,
`hdhub4u`, `hianime`, `moviesmod`, `vegamovies`, `mapple`, `movieblast`, `showbox`.

`ctgmovies` also exceeds the 45 s provider budget. `torrentio` returned 15 results but they
were magnet links; the Nuvio collection plays direct URLs and does not hand a magnet to the
debrid path, so it reports no playable stream. Using Torrentio is what the Original collection
already does.

## Blocked by the validator

These are technical blocks, not licensing judgements. The manifest listed them, but the source
does not satisfy the literal-module rule or uses a capability Roki will not execute:

- **Dynamic `require` (the destination cannot be checked before running):** `allanime`,
  `allmovieland`, `topcartoons`, `vixsrc`, `allwish`, `castle`.
- **`eval` / dynamic code:** `animekai`, `animepahe`, `anime-sama`.
- **WebAssembly:** `1shows`.
- **Host process / DOM access:** `peachify`.
- **Plain `http`:** `animedekho`, `animesalt`, `animepahe`.
- **Filesystem / process inside `anime-sama`:** also blocked by `fs`, `process`, `eval` and
  `Function`.

`vixsrc` additionally wants raw `http`/`net`/`tls`/`zlib`, but its obfuscated dynamic
`require` is enough to reject it without resolving those modules. Providers that require
`cheerio-without-node-native` or `crypto-js` are now eligible when nothing else fails.

`1shows` and `animekai` are the clearest examples of the trade-off: they returned streams in
the probe, but the validator refuses capabilities Roki cannot safely contain. They are not
enabled by default and cannot be enabled around the validator.

## Content authorisation and licensing

The manifest is a catalogue, not a licence. A provider being listed does not mean it is
authorised for every title or in every jurisdiction. Roki never turns a provider on by
default: each one is switched on by the account, and the Settings section carries a notice
saying so. Roki does not host
media, does not decrypt DRM, and does not bypass access controls. Whether a provider is
lawful for a given title remains the account holder's responsibility.
