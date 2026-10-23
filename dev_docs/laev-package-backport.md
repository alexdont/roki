# Move roki-side work back into the laev package

Status: **not started** (written 2026-10-23, after laev 0.1.41 shipped with the new sync address).
Goal: the terminal-app (CLI-only) users get the same clean source, subtitle and conversion behaviour that
roki had to work around. Roki then deletes its workarounds. Roki stays the LiveView/UI/per-user layer.

Order by value: **1 and 3 first** (they fix wrong results and runaway CPU for every CLI user), then 2, 4, 5, 6.

## 1. Picking the right episode (bug fixes)
- `Laev.FilePick.choose/3` falls back to the LARGEST file in a pack when none names the episode ("S1E2 plays
  13v2"). Return "no match" unless the caller asks for the fallback.
- `Laev.FilePick.names_episode?/3` reads "13v2" (a re-release) as episode 2. Strip `(\d)v\d` first.
- Packs numbered across a merged TMDB season ("(13-25)", range start != 1) must be asked for the TMDB number,
  not the cour-local one: roki `numbered_as/2` in `lib/roki/watch/resolver.ex`.
- Reject a pick whose file names another episode or cour (`S02E01` for S1E2; bare `- 13v2`) and a pack with no
  file for the episode: roki `confirm_episode/3`, `wrong_numbering?/2`, `pack?/1`, `names_episode?/3`.
- Probing: `probe_page` runs 4 at a time, groups releases by the number they use, stops early once 5 play
  (`@enough`, `@grace_ms`): `lib/roki/watch/resolver.ex`.

## 2. Anime numbering and MyAnimeList
- `lib/roki/watch/anime.ex`: `parts`, `locate/3`, `first_entry/1` (TMDB season -> MAL entries, episode local to
  each entry). The package has `Laev.AnimeMap` but not this layer.
- `lib/roki/watch.ex`: `sections/2`, `play_for/4`, `next_unseen`, `section_counts`, `episode_tag`,
  `next_episode`/`previous_episode` (season/part picker, "continue where you were").
- The CLI has a private `mal_page` (`cli.ex`, opens the MAL entry you watched most). Make it public; roki
  re-implemented it for the "Open on MyAnimeList" link (`external_links/2` in `title_live.ex`) and per-season
  rating (`rating_target(title, entry)` in `watch.ex`).

## 3. ffmpeg conversion (`Laev.Remux.Worker`)
- Encodes with `libx264 -b:v 6M`, no speed preset, full resolution: a 4K HEVC release never keeps up and takes
  every core. Add a fast preset and a size cap.
- A worker lives 2 hours whatever happens. Stop it when "ready" times out, and when nothing has been requested
  for ~10 min: roki `lib/roki/watch/reaper.ex` (`touch(id)` from the stream controller) and `ready_or_stop/1`.
- Refuse a 4K+ re-encode in the browser target and cap concurrent encoders: `Roki.Watch.start/4` (`:too_heavy`,
  `:busy`), `heavy?/1`.
- Incident that showed it: 2026-10-23, French Lupin 4K H.265, load average ~150, four ffmpegs.

## 4. Subtitles
- `Laev.SubtitleFetch.fetch` returns only the best OpenSubtitles match. Expose listing the choices
  (`os_search` in `watch.ex`) and a download kept on disk by file id (`lib/roki/sub_cache.ex`), plus a negative
  cache (free quota is small).
- `Laev.OpenSubtitles.verify_login/2`: username, NOT email (API answers 400), clear messages for 400/401/429
  (`check_os_login` in `lib/roki/laev.ex`).
- `OPENSUBTITLES_USERNAME` / `OPENSUBTITLES_PASSWORD` are not options in `Laev.Settings`; roki writes them with
  `Config.write` + `Scope.set` (workaround). Make them real settings.
- Jimaku: `jimaku_tracks` in `watch.ex` offers up to 5 plausible Japanese files, the release group's own first.
  The package takes the first it finds (often ~30 s off).
- `Roki.Subtitles.to_vtt` converts more formats than the package's SRT-only `srt_to_vtt`.

## 5. First-run setup
- `Roki.Laev.setup/2` (`lib/roki/laev.ex`): validate keys, generate a laev key, connect with keys carried, roll
  back on failure. The CLI wizard generates its key in a private function (`gen_sync_token`): same job twice.
  Public `Laev.Setup.first_run/1` for both. Same for `replace_key` (save only if the service accepts it).

## 6. Sync server
- The blog and roki each have a copy of the same store and merge code (`lib/roki/sync_store.ex`,
  `lib/roki_web/controllers/sync_api_controller.ex`, `raw_body_reader.ex`). Ship one `Laev.SyncServer` module with
  a storage adapter; then delete the blog's copy.

## Stays in roki
LiveView pages and player UI, per-user folders, per-user source cache, external-player hand-off links (VLC/m3u).

## Already done (do not redo)
- Sync store moved to roki at `https://roki.ee/api/laev`; old `sasha.don.ee/laev` is forwarded by Caddy and must
  keep working. laev 0.1.41 has the new default address. Blog table/code still exist (unused): drop them after a
  few days of normal use. Backups: `/docker/sdon/data/backups/` (`laev-documents-2026-10-23.sql`).
