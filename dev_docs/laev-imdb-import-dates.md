# laev: dates for a catalogue imported from TMDB

`Laev.Ratings.import_from_tmdb/1` marks everything rated on TMDB as watched, but TMDB's v3
`account/{id}/rated/*` items carry no rating date, so every mark is written with the moment of
the import. A user who brought a decade of IMDb ratings to TMDB sees all of it "watched today"
in stats, `Shelf` and any history built from the marks (roki.ee hit this on 2026-10-29: 535 titles).

What is available, in order of preference:

1. **TMDB v4** `GET /4/account/{account_object_id}/{movie|tv}/rated` returns
   `account_rating.created_at`. It needs a v4 user access token (`/4/auth/request_token` ->
   approval -> `/4/auth/access_token`), which laev's v3 session does not provide. Note that for
   ratings TMDB itself imported from IMDb, `created_at` is likely the import day, not the real one.
2. **IMDb ratings export** (`Const`, `Date Rated`, `Title Type`). The only source of the real dates.
   Suggested API: `Laev.Ratings.import_imdb_csv(csv_binary, report)`: resolve `Const` with
   `Tmdb.find_imdb/1`, skip `TV Episode`, and write the mark with that day as its date
   (instead of "now"). Idempotent; never overwrite a date laev already holds from a real play.

roki.ee now does (2) itself in `Roki.ImdbDates` (it dates the site's own watched table, not laev's
mark files), so laev's marks from an import are still undated until this lands.
