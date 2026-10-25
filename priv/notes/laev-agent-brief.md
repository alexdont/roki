TASK 2: make laev do what roki currently works around (release after the anime-franchises task)

Roki (a Phoenix site that uses laev as a library for many users) patched the items below in
the app because the package could not be changed. Each should live in laev so the CLI gets it
too and roki can delete its copy. Do them in this order; 1-4 are the most valuable.
Keep every existing public function working. For each item: add tests, and tell me the new
function names so roki can switch to them.

------------------------------------------------------------------------------------------
1. REMUX START IS SLOW: ONE ffprobe INSTEAD OF FOUR   (lib/laev/remux/worker.ex)
Today the worker runs four ffprobe processes one after another before ffmpeg starts:
probe_subs/1 (line ~44), then probe/1 (= ffprobe(url,"v:0") and ffprobe(url,"a:0"), line ~94),
then probe_audios/1 (line ~95). Each re-opens the same remote URL, so it costs about 7.3s
before the first segment; a single call takes about 1.8s.
Do: one call, e.g.
  ffprobe -v error -show_entries stream=index,codec_type,codec_name:stream_tags=language
          -of json <url>
and derive from it: the video codec, the first audio codec, the list of audio streams with
language, and the embedded subtitle list (same skipping of hdmv_pgs_subtitle / dvd_subtitle /
dvb_subtitle as probe_subs does today, same %{index, lang, file: "sub#{n}"} shape).
Behaviour of the worker must not change except being faster. A probe failure keeps today's
fallbacks ("" / []). This is the biggest single cost of pressing Play in the browser.

------------------------------------------------------------------------------------------
2. PER-REQUEST LANGUAGE OVERRIDE, STRICT AUDIO FILTER, RESOLUTION LIMIT
Roki added "study mode": one title in languages chosen for it, without touching the user's
settings. It needed three things laev does not offer.

2a. A scoped override of settings that follows async work.
Roki keeps the override in the process dictionary and merges it when it builds the scope:
  # Roki.Study
  def bind(overrides), do: Process.put(:roki_study, overrides)      # %{lang: "fr", subs_lang: "fr"}
  def current, do: Process.get(:roki_study) || %{}
  def wrap(fun), do: (o = current(); fn -> bind(o); fun.() end)     # for Task.async / start_async
  # Roki.Laev.run/2
  overrides = lent |> Map.merge(app_keys()) |> Map.merge(Roki.Study.current())
  dir |> Laev.Scope.load(overrides) |> Laev.Scope.run(fun)
Do: a public way to run a function with some settings replaced, e.g.
  Laev.Scope.with_overrides(%{lang: "fr", subs_lang: "off"}, fun)
that works inside a bound scope, restores afterwards, and is carried by Laev.Scope.async /
async_stream the way the scope itself already is. (Roki's own Task.async calls do not inherit
the scope; the existing helpers do, so that is where this belongs.)

2b. Keep only releases whose AUDIO has the language.
Roki: after probing, with a study override active, it keeps a release only when the language
appears in the audio tracks read from the file itself (attach_tracks -> source.langs):
  want in Enum.map(source.langs || [], &short_code/1)
Subtitles alone must not count: someone learning French needs French speech.
Do: Laev.Sources.audio_in?(source, lang) (and a ranking option such as strict_audio: lang) so
callers don't re-implement it. Unknown tracks (not read yet) must be distinguishable from
"read, and not this language".

2c. Resolution limit before checking releases.
Roki drops everything above 1080p before probing, for the browser (Laev.Sources.at_most(
sources, "1080p") then Laev.Sources.rank). Do: a max_resolution option on the search/rank path
so the limit applies before releases are checked, not after.

------------------------------------------------------------------------------------------
3. ANIME EPISODE LENGTHS: LEARN WHAT IS MISSING   (Laev.Anime.Parts, Laev.Anime)
TMDB merges cours into one season (You and I Are Polar Opposites: TMDB S1 = 25 episodes,
MAL 60371 = 12 + MAL 63832 = 13). Laev.Anime.Parts.parts/2,3 and locate/3 lay the MAL entries
end to end using Laev.Anime.episodes(mal) - which reads the CURRENT USER'S anime list. For an
account whose list lacks the first entry the count is nil, parts/3 drops that entry ("unknown
length is skipped unless it is the last") and every episode lands on the second cour:
episode 7 searched as S02E07, episode 19 as "19". Nothing looked wrong until a second
account tried it.
Roki's workaround (Roki.Watch, called before locate/parts):
  defp learn_parts(%{anime?: true, type: "tv", id: id}) do
    for mal <- Laev.AnimeMap.mal_ids("tv", id), Laev.Anime.episodes(mal) == nil do
      Laev.Anime.learn(mal)      # asks MAL once and remembers it
    end
    :ok
  end
Do: make Parts.parts/locate do that themselves (learn missing lengths, once, remembered),
and fall back to Kitsu (or Jikan) when MAL is unavailable or the app has no client id, so the
answer never depends on whose list is loaded. Keep "never from a list" in mind: learn at the
point of locate/parts, not while rendering a long list; add a cheap `Laev.Anime.Parts.ready?`
check if useful.

------------------------------------------------------------------------------------------
4. TMDB RECOMMENDATIONS   (Laev.Tmdb)
Roki shows "More like this" on a title page. Laev.Tmdb has no call for it and its get/2 is
private, so roki calls TMDB itself with Req + Laev.Scope.get(:tmdb_key) (lib/roki/similar.ex):
  GET /{movie|tv}/:id/recommendations, topped up from /similar, dedupe by id, drop the title
  itself and results with no poster, keep 12.
Do: Laev.Tmdb.recommendations(type, id) and Laev.Tmdb.similar(type, id), returning
{:ok, [card]} with the SAME card shape as trending/2:
  %{id, type, title, year, poster (w342 url), overview, vote, popularity}
Same auth (bearer for "eyJ" keys), same error shapes as the other calls.

------------------------------------------------------------------------------------------
5. SCORE WORDS AS PUBLIC DATA
The ten rating words (10 masterpiece, 9 banger, 8 really good, 7 pretty decent, 6 it's alright,
5 passable, 4 not good, 3 truly bad, 2 garbage, 1 absolute trash) are @scores in Laev.CLI
(private). Roki's rating slider needs them, so they now exist twice (Elixir + JavaScript).
Do: a public Laev.Ratings.score_words/0 (ordered list of {score, word}) and score_word/1
(rounds to the nearest whole score, clamps to 1..10; works for integers AND floats - roki hit a
crash by calling Float.round on an integer 7). Make the CLI use it.

------------------------------------------------------------------------------------------
6. SLOW RELEASE SITES   (Laev.Sources)
Anime searches wait on Nyaa for about 16 seconds, and everything waits for the slowest site.
Do: a per-backend deadline (option, e.g. backend_timeout: 6_000) after which the search
returns what the other sites gave, with the slow backend marked as "late" so a caller can ask
again. Default behaviour may stay as it is; roki will pass a deadline.

------------------------------------------------------------------------------------------
7. SMALLER THINGS
- Language settings: Laev.Config.lang/0 and subs_lang/0 should accept "fr", "FR", "fre", and
  "French" and return one normalised code, so a setting typed by hand in the CLI means the same
  as roki's dropdown ("fr"). Today a wrong value just ranks nothing first.
- A public Laev.Playback.heavy?(source) (true when a browser cannot play it without a software
  re-encode: HEVC/AV1, 4K). Roki has its own copy of the rule and delegates to laev where it can.
- When the cross-id list gives one TMDB show MAL ids that belong to a different TMDB show
  (see the Bleach check in task 1 of the franchises work), log a clear warning instead of
  returning the muddled list silently.

------------------------------------------------------------------------------------------
HAND BACK
New package version, plus for each item above the new function names/options, so roki can
replace its copies: Roki.Study/in_study_order/spoken_in_study_language, Watch.learn_parts,
Roki.Similar, the score words in title_live.ex + assets/js/app.js, and the Remux timing.
