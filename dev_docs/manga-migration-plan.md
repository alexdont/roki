# Bringing the manga reader into roki

The reader on `sasha.don.ee` (the `:habit_tracker` app, database `dev_habit_tracker_db`) moves
here. It is not a port of a second product into the same deployment: a manga is meant to behave
like a film does — shelved on a profile, rated, in the activity feed, commented on, searched for —
so the work is as much integration as it is migration.

Nothing in this document is built yet. It records the decisions and the order, because several of
them are cheap now and expensive once there is data.

## The keystone: a manga is a title with an integer id

Everything on roki's profile side keys on `(type, id)` with an **integer** id — `roki_favorites`,
`roki_watched`, `roki_ratings`, `roki_activity` all do. A manga in the reader is keyed
`(source, slug)`: two strings. Resolving that mismatch is the whole design.

**A new `roki_manga_titles` table holds the site's own copy of a series** — `id` serial primary
key, unique on `(source, slug)`, plus title, cover, `mal_id`, and a `data` jsonb for what the
source said. It is the same shape and the same purpose as `roki_titles`, which already does this
for TMDB.

With that in place a manga is `type: "manga", id: <that serial>` and **not one column changes
anywhere else in roki**. It shelves, rates, appears in the feed and carries comments through the
machinery that already exists. `roki_watched.status` is already `finished | progress |
up_to_date | on_hold`, which is the manga vocabulary too (completed, reading, caught up, on hold),
and the reader already writes exactly those three events into `library_events`.

The packaged reader keeps speaking `(source, slug)`. Translation happens in the adapter — that is
what the adapter is for — so no reader package is touched.

## What stays where

| State | Lives in |
|---|---|
| Reading position, per-device reading mode, timers, spread overrides, marks, categories, tier list, grid | the reader's own tables, renamed `roki_manga_*`, keyed `user_uuid` + `manga_id` |
| Shelf-level status (reading / caught up / completed / on hold) | `roki_watched`, as a `"manga"` row |
| Top ten | `roki_favorites`, kind `:manga` (already supported) |
| Score | the tier list for now; mirrored into `roki_ratings` only where a MAL link exists |
| Chapter reads worth announcing | `roki_activity`, grouped like a binge |
| The 13 reader settings | `roki-web.json` via `Roki.Laev.web_setting_specs/0` |
| Covers | `Roki.Images` (its MAL CDN whitelist already passes `manga/` paths) |
| Chapter pages | a new streaming proxy, never stored |

Reader tables are renamed to roki's conventions on the way in (`saved_manga` →
`roki_manga_library`, `manga_*` → `roki_manga_*`, `user_id` → `user_uuid`). The migrations are
being rewritten anyway, so it costs nothing now and cannot be done later without touching live
data.

## The reader must not break

It keeps serving `sasha.don.ee`, untouched, for the whole of this. That has consequences:

- **Data is copied, never moved.** A re-runnable mix task in roki reads `dev_habit_tracker_db`
  through a second, read-only Repo and writes roki's tables. No DDL on the reader's database, no
  locks, nothing removed. Run it as often as convenient; run it once more at cutover to pick up
  the delta.
- **Reading continues on the old site until cutover.** Until then roki's manga section is the
  owner's preview. Two live copies of a reading position would diverge, and bidirectional sync for
  three people is not worth writing.
- **roki gets its own sidecar container**, so the two never contend. Both scrape the same sources
  from the same host IP, which is worth remembering if a source starts refusing.
- The only change to the reader's repo is the Phase 0 commit, which changes nothing at runtime.

## Phases

**0 — safety.** Commit the reader's working tree: 23 modified and 14 untracked files, including
~2,400 lines of panel-detection JS and two migrations a clone would silently lose. Dump both
databases.

**1 — the spike (half a day, go/no-go).** Upgrade roki's PhoenixKit 2.54.2 → 2.63.0 (the reader is
ahead; this also makes the two user tables identical). Mount the packaged reader's router macro at
a throwaway route with stub behaviours and render one chapter. The packages were extracted by that
app for that app; if they leak host assumptions, this is where it shows, for a day rather than a
fortnight. The fallback — porting the controller and templates directly — roughly triples the
estimate, which is worth knowing before Phase 2 and not after.

**2 — foundations.** The sidecar as its own compose service on `backend-net` (not a second
supervisord program inside `roki-ee`: a JVM crash then cannot take the site down, and the Elixir
image stays clean). The page proxy, behind `Roki.RateLimit` keyed by `RokiWeb.Client.key/2`.
`roki_manga_titles` and the renamed reader tables. The settings specs. A dry run of the copy task.

**3 — the reader, working.** The five behaviours (store, annotations, GIFs, current user, URLs)
against the real tables. Routes inside `live_session :site`, **before** `live "/:username"` (a
single-segment catch-all) and before `phoenix_kit_routes()`. The disabled "Manga · soon"
placeholders in `layouts.ex` (lines 107 and 333) become a real `sections` entry. The reader view
goes on `RokiWeb.SyncPull`'s skip list so a background sync cannot reload the page mid-chapter.
Done when a chapter reads at `roki.ee/manga/…` in roki's chrome with progress saved.

**4 — library pages in roki's voice.** Shelf, series, and a continue-reading row on `/home`,
written fresh against `PosterComponents.poster/1`, `InfiniteScroll` and `FillGrid`/`KeepPlace`.
The old app's ~11,500 lines of inline template JS stay behind; this is where that debt is dropped.

**5 — folded in.** The profile is the point here, and it should not look like a bolted-on second
product:
- `Roki.Profile.kinds/0` gains `manga: "Manga"` — that is the history and ratings filter. The
  shelf list already has it.
- `candidates/3` learns to offer the manga library instead of watch history.
- The history grid sorts manga among films through the existing `arrange/5`, because a manga row
  is an ordinary `(type, id)` row.
- Search: the existing `/search` page gets a tab strip (All · Films · Shows · Anime · Manga) where
  **Manga is a link to `/manga/search?q=…`, not an in-page filter**. Film search is one TMDB call
  in ~200 ms; manga search fans out across extensions and streams results in as each source
  answers. Mixed into one grid, either the films wait for the slowest scraper or the grid
  reshuffles under the cursor. One search box, one query string, two result pages.
- Comments: `"manga" => Roki.CommentHandler.Manga` in `config.exs`, with `Roki.Social.title_uuid/2`'s
  UUIDv5 trick for the thread id.
- Notifications: a new-chapter kind is one tuple in `Roki.Notify`'s `@kinds`.

**6 — MAL manga.** `/v2/manga/<id>`, `/v2/users/@me/mangalist` and the progress push, on the token
the owner and max already hold. **No app registration is needed** — roki has its own MAL client and
callback; the reader's hardcoded `sasha.don.ee` redirect is dropped with the rest of its OAuth half.
What must come across is `manga_mal_links`: MAL cannot say which scraper slug is which MAL id.

**7 — the data.** Three accounts, by decision of the owner: reader `sasha` → roki `alex`,
`maxdon2001` → `max`, `masha` is new. 2,802 of 2,903 rows and 115 of 138 series; the other fifteen
reader accounts never finished a chapter and are not migrated. Their password hashes are bcrypt and
portable, but no session tokens are carried — everyone logs in once. Verify by counting rows per
user on both sides and opening the migrated library.

**8 — cutover.** `sasha.don.ee` serves until the owner is satisfied, then a final delta copy, then
a redirect. Tell masha her account moved; the unmigrated accounts need no message, since none of
them has data to explain.

## Still open

- Whether the tier list stays the manga rating mechanism or gives way to roki's 0–10 scores. Two
  rating systems for one thing is a mess; postponed deliberately, not forgotten.
- Whether unlinked series (no MAL id) are shelvable. With `roki_manga_titles` they are, which is
  the reason to prefer it over keying on MAL ids.
