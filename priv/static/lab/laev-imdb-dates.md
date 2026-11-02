# laev task: date a catalogue imported from TMDB by when it was rated

Written 2026-10-29 from roki.ee (a Phoenix site that embeds laev `~> 0.1.47`). You do not have
roki's source, so everything needed is here. Laev source is yours; roki only consumes the hex package.

## The bug

`Laev.Ratings.import_from_tmdb/1` marks every film/show rated on the TMDB account as watched via
`Position.set_watched(ctx, true)`, with no date. The marks therefore carry the moment of the
import. TMDB's v3 `GET /account/{id}/rated/{movies|tv|tv/episodes}` items have NO rating date
(keys: adult, backdrop_path, genre_ids, id, media_id, media_type, original_language,
original_title, overview, popularity, poster_path, rating, release_date, title, video,
vote_average, vote_count), and `Laev.Tmdb.rated/2` just returns them.

Observed on a real account: it had a decade of IMDb ratings copied into TMDB (365 films, 186
shows). After `import_from_tmdb`, 535 titles read as "watched today" in `Shelf`, in stats and in
roki's history. Roki worked around it on its side (below), but CLI users get the same wrong
history from laev itself.

## What exists to get the real dates

1. **IMDb ratings export (CSV).** The only place the real dates live. Header:
   `Const,Your Rating,Date Rated,Title,Original Title,URL,Title Type,IMDb Rating,Runtime (mins),Year,Genres,Num Votes,Release Date,Directors`
   Example row: `tt26915336,8,2026-10-20,"Mars Express","Mars Express",https://www.imdb.com/title/tt26915336,Movie,7.5,88,2023,"Animation, Sci-Fi",15860,"2024-05-03","Jérémie Périn"`
   `Title Type` values seen: Movie (343), TV Episode (219), TV Series (173), TV Mini Series (24),
   Short (11), TV Movie (7), Video (2), TV Special, TV Short. Quoted fields contain commas, use
   a real CSV parser (NimbleCSV.RFC4180); a leading BOM may be present.
2. **TMDB v4** `GET /4/account/{account_object_id}/{movie|tv}/rated` returns
   `account_rating.created_at`, but needs a v4 user access token (request_token -> user
   approval -> `/4/auth/access_token`) which laev's v3 session does not have. Also: for ratings
   TMDB itself imported from IMDb, `created_at` is probably the import day, so it may not help.
   Treat it as optional.

## What to build

`Laev.Ratings.import_imdb_csv(csv_binary_or_path, report \\ fn _ -> :ok end)`:

- Parse the export; keep rows whose `Const` starts `tt` and `Date Rated` is an ISO date; skip
  `TV Episode` rows (or map them to episode marks only if you can do it reliably; roki skips them
  and dates the show as a whole).
- Resolve each `Const` with `Laev.Tmdb.find_imdb/1` (returns `{:ok, %{...}}` with the media type
  and TMDB id, or `{:error, :not_found}`); do it concurrently (8 at a time worked, ~560 lookups
  in well under a minute) and de-duplicate by `Const`.
- Mark the title watched **with that day as its date** instead of "now" (movie: `movie-<id>`;
  show: the title-level `tv-<id>` mark, same as `ctx_for_show/1` does today). Find how a mark can
  carry a time: the position file mtime, a `played/` or `ticks/` entry, whatever `Shelf`'s
  `last_watched_at` reads for a title with no measurement; per 0.1.47 only a tick-log session or
  >=2 min of measurement counts, so decide deliberately which source a *claimed* date should be
  written to, and make sure `last_watched_at` then returns it. Roki's stats/history show the
  result, so this must not be read as "played 4 seconds".
- Never overwrite a date laev already holds from a real play, and never stamp a part-watched
  position as finished (`decide/1` already guards this; keep it).
- Idempotent, returns counts like `import_from_tmdb/1` plus `unresolved`.
- Also make `import_from_tmdb/1` stop pretending: when it marks titles it has no date for, the
  marks should be recognisably "undated" (not today) so a later `import_imdb_csv` can date them.
  Today an undated import is indistinguishable from a watch today. This is the part that
  actually fixes the symptom for people who never run the CSV step.
- Terminal UI: a menu entry/command that asks for the CSV path.
- Tests, changelog entry (0.1.48), and a note in the moduledoc of `Laev.Ratings`.

## What roki did meanwhile (so you do not duplicate or contradict it)

- Roki keeps its own table of watched titles and dates and does the CSV matching itself
  (`Roki.ImdbDates`): resolve `Const` with `Tmdb.find_imdb`, date only titles that are watched and
  have no date set by the person, group by day. Once laev dates marks properly, roki's copy can
  read the dates from laev and that module can go.
- Roki also now treats more than 25 newly-finished titles appearing in one sync as an import and
  leaves them undated, instead of stamping them "now".

Please keep the public API additive (`~> 0.1.47` consumers must keep compiling) and tell the
user the new version when published.
