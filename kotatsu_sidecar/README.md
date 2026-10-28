# kotatsu-sidecar

A thin Kotlin/Ktor HTTP wrapper around
[kotatsu-parsers-redo](https://github.com/Kotatsu-Redo/kotatsu-parsers-redo) —
1,000+ community-maintained manga site parsers — consumed by the
Phoenix app through `HabitTracker.MangaSource.Kotatsu` (an adapter
behind the `HabitTracker.MangaSource` behaviour).

> Lineage: the original
> [KotatsuApp/kotatsu-parsers](https://github.com/KotatsuApp/kotatsu-parsers)
> was archived in Nov 2025; kotatsu-parsers-redo is the actively
> maintained community continuation (same packages, drop-in API).

```
┌────────────────────────┐   HTTP (localhost)   ┌──────────────────────────┐
│ Phoenix app            │ ───────────────────► │ this sidecar (Ktor)      │
│  MangaSource behaviour │                      │  kotatsu-parsers         │
│  └ Kotatsu adapter(Req)│ ◄─────────────────── │  MangaLoaderContextImpl  │
└────────────────────────┘   JSON + image bytes └──────────────────────────┘
```

## Build & run

Requires JDK 17+ (built and run here on 21) and Gradle 8.x.

```bash
gradle shadowJar            # → build/libs/kotatsu-sidecar.jar
PORT=8420 java -jar build/libs/kotatsu-sidecar.jar
```

Binds `127.0.0.1` ONLY — the sidecar has no auth; never expose it.

In this container it runs under supervisord (the `[program:kotatsu]`
block in `/etc/supervisor/conf.d/elixir-app.conf` — supervisord here
is started with `-c` on that file, so the include dir is not read):

```bash
supervisorctl status kotatsu
supervisorctl restart kotatsu
tail -f /var/log/kotatsu-sidecar.log
```

A `Dockerfile` + `docker-compose.yml` are provided for running it as
a container elsewhere.

## HTTP API (JSON, camelCase)

| Endpoint | Purpose |
|---|---|
| `GET /health` | `{"status":"ok","parsersVersion":"…"}` |
| `GET /sources` | catalog: `name` (stable key), `title`, `locale`, `contentType`, `broken` |
| `GET /sources/:name/search?q=…&page=1` | search within a source |
| `GET /sources/:name/manga?url=…` | details + chapter list |
| `GET /sources/:name/pages?chapterUrl=…` | page list with final `imageUrl` + `proxyPath` |
| `GET /sources/:name/image?url=…` | image proxy — carries the parser's Referer/cookies; reader `<img>` tags must use this (via the app's `/reader/kotatsu/image` route), never upstream CDN URLs |

Errors are JSON, never stack traces:
`404` unknown source / not found, `401` auth required, `429` rate
limited, `502 {"error":…,"kind":"cloudflare"|"parse"|"http"}`.
`kind:"cloudflare"` means an interactive challenge the sidecar cannot
solve (accepted v1 limitation; the UI should message it per-source).

## Design notes

- **Stateless**: kotatsu APIs take model objects; endpoints accept
  bare URLs and reconstruct skeletons with the library's
  `generateUid(url)` + the url + source. `getDetails`/`getPages` work
  on such skeletons. This keeps the Elixir side free of session
  bookkeeping. If a parsers bump changes `Manga`/`MangaChapter`
  required fields, `mangaSkeleton`/`chapterSkeleton` in `Main.kt` are
  the two places to fix.
- **Parser instances are cached** per source (they hold cookie/session
  state some sites need across calls).
- `MangaLoaderContextImpl` + interceptors are adapted from
  [kotatsu-dl](https://github.com/KotatsuApp/kotatsu-dl), the official
  plain-JVM example (Cloudflare detection, GZip, 429→exception,
  per-source headers, Nashorn `evaluateJs`, AWT image handling).
- **Search ordering** uses each parser's `defaultSortOrder`, not
  RELEVANCE — at the pinned commit MangaDex renders RELEVANCE into a
  malformed query (upstream bug). Pagination is exposed as a simple
  `page` int mapped to `offset = (page-1)*20`; exact for page 1,
  approximate beyond (sources learn their own page size internally).

## Pinned parsers version & bumping it

Pinned in `build.gradle.kts` (`parsersVersion`, a git commit of
kotatsu-parsers resolved through JitPack). Bumping it = picking up
community site fixes — expect to do this regularly:

1. Pick a new commit hash from
   https://github.com/Kotatsu-Redo/kotatsu-parsers-redo/commits/master
   (short 10-char form).
2. Update `parsersVersion` in `build.gradle.kts`. Also re-check their
   `gradle/libs.versions.toml` for the **okhttp** version and keep our
   explicit okhttp dependency in sync — parsers reference okhttp
   internals, and a mismatch breaks some sources at runtime with
   `NoClassDefFoundError`.
3. `gradle shadowJar` — the FIRST resolution of a fresh pin triggers a
   remote build on jitpack.io: it can take minutes or flake once.
   Just retry.
4. Sanity-check the skeleton reconstruction (the one integration
   detail most likely to shift between releases):
   `curl 'localhost:8420/sources/WEEBCENTRAL/search?q=one%20piece'`,
   then `/manga?url=…` with a result's `url`, then `/pages`.
5. `supervisorctl restart kotatsu`.

## Known limitations (accepted v1)

- No interactive-Cloudflare sources (would need FlareSolverr); they
  fail with `kind:"cloudflare"`.
- No auth-required sources (parsers support per-source credentials —
  out of scope).
- Kotatsu's catalog, not Tachiyomi/keiyoushi's — overlap is large but
  not total: https://kotatsu.app/parsers/
- MangaDex specifically blocks datacenter IPs at the edge (HTML 400s
  even on `/ping`) — from a server it may be dead regardless of the
  sidecar; residential/home deployments are fine.
