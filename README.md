# Roki

A personal media viewer: a shelf of what you watch and read, and a player that plays it in the
browser. Built with Phoenix LiveView; live at [roki.ee](https://roki.ee).

It is a viewer, not a library. Roki hosts no media. What plays comes from accounts and links that
**you** connect — your own Real-Debrid or TorBox account, or an addon link you copy from a service
you use — and every account brings its own.

## What it does

- **Shelf, history and stats.** What you are watching, what to continue, a calendar of new
  episodes, ratings, lists, and a profile. Movie and show data comes from TMDB; the terminal app
  [laev](https://github.com/alexdont/laev) (my own Elixir library) does the heavy lifting behind it,
  so the website and the command line share one history.
- **Two kinds of source, one player.** Torrent releases through a debrid account, or plain https
  streams from a PenguPlay (Stremio-style) addon link. A switch on the sources page and in the
  account menu picks which one Play uses; Play then finds the best stream by itself and falls back
  to the next if one fails to start.
- **A player that works in the browser.** Files are taken apart and decoded on the viewer's device
  (Mediabunny → MediaSource, so 4K HEVC and Dolby/DTS audio play without server work); playlists go
  through hls.js; anything else is converted by ffmpeg on the server. Resume position, subtitles
  (embedded, from the stream, or OpenSubtitles/Jimaku), audio tracks and a study mode for learning a
  language from subtitles.
- **A manga reader** with OCR-assisted panel reading, a Kotatsu-extension sidecar (Kotlin) for
  sources, and reading progress that syncs to MyAnimeList.
- **Accounts that can lend each other access.** The owner can lend their API keys, or their
  PenguPlay link, to chosen accounts with a per-account daily cap, and see who used what.
  Accounts with nothing connected are told exactly what to connect and where to get it.

## How it is built

| | |
|---|---|
| Web | Phoenix 1.8 / LiveView 1.2, Tailwind + daisyUI, esbuild |
| Data | PostgreSQL through Ecto; per-user files for laev's state |
| Accounts, admin, media | [PhoenixKit](https://hex.pm/packages/phoenix_kit) |
| Playback | Mediabunny, hls.js, ffmpeg; browser decoding first, server conversion as the fallback |
| Tests | ExUnit (~90 test files) and Playwright scripts for the player |

The code is Elixir first, with the player and reader in plain JavaScript modules
(`assets/js/study/`) and a small Kotlin service (`kotatsu_sidecar/`).

Notes on how things work and why live next to the code: [`CLAUDE.md`](CLAUDE.md) (architecture and
operations) and [`dev_docs/`](dev_docs/).

## Running it

You need Elixir 1.19, PostgreSQL (with the `citext`, `pg_trgm` and `pgcrypto` extensions) and
ffmpeg. All configuration comes from environment variables, read in one place
(`config/runtime.exs`); nothing secret is kept in the repository.

```bash
export DB_USERNAME=… DB_PASSWORD=… DB_DATABASE=roki \
       SECRET_KEY_BASE=$(mix phx.gen.secret) LIVE_VIEW_SIGNING_SALT=$(mix phx.gen.secret 32)
mix setup          # dependencies, database, assets
mix phx.server     # http://localhost:4000
```

Optional: `TMDB_API_KEY` (the public Featured page), `MAL_CLIENT_ID` / `MAL_CLIENT_SECRET`
(MyAnimeList). Each user adds their own debrid keys or PenguPlay link under Settings.

```bash
mix test
```

## About this repository

Roki was built over about ten days (October 2026), in small commits, pair-programming with
[Claude Code](https://claude.com/claude-code). The history is the working log: most commits say why
a change was made, not only what changed.
