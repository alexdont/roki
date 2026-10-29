defmodule Roki.Stats do
  @moduledoc """
  What a user has watched, totalled — laev's own stats, made safe to run on a server.

  Laev measures time from TMDB runtimes (cached per film and per show) and from
  MyAnimeList's episode lengths for anime. Two things about that go wrong on a
  server, and this module exists to stop them:

  * **A lookup that fails is cached as "unknown" forever.** Run before the user's
    TMDB key has arrived and every film, show and series is remembered as having
    no length — the stats then count only the anime, and read a third of the real
    figure. So `build/0` refuses to run without a key, and repairs a cache that is
    mostly "unknown" (a real show with no listed runtime is rare; hundreds in a row
    is a failed run) so the next measurement does the lookups properly.
  * **The day-by-day log can be corrupt.** Synced `watched/*.log` files sometimes
    have entries fused onto one line (`2026-10-22 12026-10-22 2`), which laev's
    parser reads as 12,026 seconds. Days are re-read here with a strict parser
    that splits fused entries, and a day is capped at 24 hours.

  Every function runs inside the user's laev scope — call from `Roki.Laev.run/2`.
  """

  alias Laev.{Days, Resume, Shelf, Stats}

  # Laev's own windows for "what did I watch lately": by when a title was last watched.
  @ranges [
    {:week, "Last week", 7},
    {:month, "Last month", 30},
    {:half_year, "Last 6 months", 183},
    {:all, "All time", nil}
  ]

  # A single day cannot hold more than this, however a log was mangled.
  @day_cap 24 * 3600

  # More than this share "unknown" among the TMDB-timed entries is a failed run, not reality.
  @poisoned_share 0.5

  def ranges, do: @ranges

  # How long a summary counts as current, and how long an older one is still worth showing.
  @summary_fresh_s 10 * 60
  @summary_keep_s 7 * 86_400

  @doc """
  The headline totals for the shelf's one-line strip. The full page uses `for_user/1` and is
  always live.

  Measuring is real work — a full minute the first time, nearly two seconds on every rebuild —
  and the shelf is opened far more often than the numbers change. It used to be kept ten minutes
  and then rebuilt in front of whoever opened the page next, so a short break was enough to
  make the strip arrive two seconds after everything else.

  Now an answer older than ten minutes is still handed back at once, and rebuilt behind it, so
  the page that asked is never the one that waits. Only the very first call, with nothing to
  show, has to measure. At most one rebuild is started a minute, however many pages ask.
  """
  def summary(uuid) do
    key = {:stats_summary, uuid}

    case Roki.TTLCache.peek(key) do
      {:ok, %{at: at, value: value}} ->
        if System.os_time(:second) - at > @summary_fresh_s, do: refresh_summary(uuid)
        {:ok, value}

      :miss ->
        with {:ok, value} <- measure_summary(uuid) do
          keep_summary(uuid, value)
          {:ok, value}
        end
    end
  end

  # What the strip needs, from the full measurement.
  defp measure_summary(uuid) do
    with {:ok, s} <- for_user(uuid) do
      # What each film was billed (seconds), for the profile's own hours (see Roki.Profile.counts/1).
      films = for t <- s.titles, t.type == "movie", into: %{}, do: {t.id, t.seconds}
      {:ok, %{totals: s.totals, films: films}}
    end
  end

  defp keep_summary(uuid, value) do
    Roki.TTLCache.put(
      {:stats_summary, uuid},
      @summary_keep_s,
      {:ok, %{at: System.os_time(:second), value: value}}
    )
  end

  # One rebuild a minute at most. A rebuild that fails (laev not connected, no TMDB key) is not
  # retried for that minute either, and the old answer keeps being shown.
  defp refresh_summary(uuid) do
    Roki.TTLCache.fetch({:stats_refreshing, uuid}, 60, fn ->
      Task.start(fn ->
        with {:ok, value} <- measure_summary(uuid), do: keep_summary(uuid, value)
      end)

      {:ok, true}
    end)

    :ok
  end

  @doc "Drop the cached summary — call when the user's data changed (sync, connect, disconnect)."
  def forget(uuid), do: Roki.TTLCache.delete({:stats_summary, uuid})

  @doc false
  def for_user(uuid) do
    with :ok <- Roki.RateLimit.check(:stats, {:user, uuid}, 4, 60_000) do
      Roki.Laev.run(uuid, &build/0)
    end
  end

  @doc """
  `{:ok, stats}` or `{:error, :no_tmdb_key}`. Slow the first time (one TMDB lookup per
  film and show, cached for good after); fast after.
  """
  def build do
    if Laev.Scope.get(:tmdb_key) in [nil, ""] do
      {:error, :no_tmdb_key}
    else
      heal_runtimes()
      # The anime/other split needs the cross-id list — laev fetches it here, where a
      # pause is expected, never from a lookup.
      Laev.AnimeMap.ensure()

      s = Stats.all_time()
      seen = last_seen()
      days = day_totals()
      art = posters(s.titles)
      plays = plays()

      {:ok,
       %{
         totals: Map.drop(s, [:titles]),
         titles: Enum.map(s.titles, &title(&1, seen, art, plays)),
         tally: Shelf.tally(),
         days: days,
         seasons: season_episodes(),
         windows: windows(days),
         streak: streaks(days)
       }}
    end
  end

  # ── runtimes ───────────────────────────────────────────────────────

  @doc false
  def heal_runtimes do
    path = Path.join(Laev.Scope.dir(), "runtimes.json")

    with {:ok, body} <- File.read(path),
         {:ok, cache} when is_map(cache) <- Jason.decode(body) do
      timed = Enum.reject(cache, fn {k, _} -> String.starts_with?(k, "mal") end)
      unknown = Enum.count(timed, fn {_k, v} -> v == "unknown" end)

      if timed != [] and unknown / length(timed) > @poisoned_share do
        healed =
          Map.reject(cache, fn {k, v} -> v == "unknown" and not String.starts_with?(k, "mal") end)

        File.write(path, Jason.encode!(healed))
        {:healed, unknown}
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  # ── titles and when they were last watched ─────────────────────────

  # By history timestamps for films and shows, the anime list's own for anime. A
  # title with neither — a hand mark, an import — has no date, and only "all time"
  # holds it: the imported decade stops drowning out this month's evenings.
  defp last_seen do
    history = Map.new(Resume.all(), &{{&1["type"], &1["tmdb_id"]}, &1["updated_at"]})

    anime =
      Map.new(Shelf.anime_list(), fn {mal_id, entry} -> {{"mal", mal_id}, entry[:updated]} end)

    Map.merge(history, anime)
  end

  defp title(t, seen, posters, plays) do
    key = {t.type, t.tmdb_id}

    %{
      type: t.type,
      id: t.tmdb_id,
      title: t.title,
      seconds: t.seconds,
      off: t.off,
      anime: t.type == "mal",
      last_seen: seen[key],
      poster: posters[key],
      skipped: plays[key][:skipped]
    }
  end

  # ── what the players measured, per title ───────────────────────────

  # When every play can be believed about what it skipped.
  #
  # The page began counting its own watched seconds at 1_793_282_397 (2026-10-29 13:59:57 UTC),
  # and until then the server subtracted one reported position from the last: a missed report
  # became a seek, so a skipped figure is mostly the time between two missed reports. Nothing in
  # the file says which logic wrote it — the third number a browser line carries was only added
  # to the format later, so older browser lines have two, exactly like the ones mpv writes.
  #
  # A play already open at the deploy kept the old page code, and so the old arithmetic, until
  # its tab reloaded (one was caught 39 minutes after: 5022s watched, 5973s "skipped"). So the
  # line is drawn a day later, when no tab can still be running the old page.
  @timer_fixed_at 1_793_282_397 + 86_400

  @doc """
  What laev measured for each title, from its `played/` files:
  `%{{"movie", 603} => %{timed:, plays:, skipped:, unsure:}}`.

  `timed` is every measurement. `skipped` is the part that can be believed: plays recorded after
  a day after the timer was fixed, by whichever player. `unsure` is the skipped time of every earlier play,
  which may be real seeking or may be lost progress reports and cannot be told apart.

  The date of a play is laev's own sync record of when its position file changed
  (`positions_at/0`), since a file's modification time is reset every time another device syncs.

  `skipped` is nil when no play is recent enough to believe, which is a different statement from
  zero: zero means the players saw every second and you skipped none.
  """
  def plays do
    dir = Path.join(Laev.Scope.dir(), "played")

    lines =
      case File.ls(dir) do
        {:ok, names} ->
          for name <- names,
              key = Roki.Stints.parse(Laev.Stints.item(name)),
              {watched, skipped} = read_play(Path.join(dir, name)) || {nil, nil},
              is_integer(watched),
              do: {name, key, watched, skipped}

        _ ->
          []
      end

    at = if lines == [], do: %{}, else: positions_at()

    for {name, key, watched, skipped} <- lines, reduce: %{} do
      acc ->
        recent? = believable?(Map.get(at, name))

        play = %{
          timed: watched,
          plays: 1,
          skipped: if(recent?, do: skipped),
          unsure: if(recent?, do: 0, else: skipped)
        }

        Map.update(acc, key, play, fn e ->
          %{
            e
            | timed: e.timed + play.timed,
              plays: e.plays + 1,
              skipped: add(e.skipped, play.skipped),
              unsure: e.unsure + play.unsure
          }
        end)
    end
  end

  @doc "The moment from which a skipped figure can be believed, as a unix time."
  def believable_from, do: @timer_fixed_at

  @doc "Can a skipped figure recorded when this position file changed be believed?"
  def believable?(changed_at), do: is_integer(changed_at) and changed_at >= @timer_fixed_at

  # Nil is "no figure to believe": adding a figure to it makes that figure, and adding nothing to
  # a figure leaves it alone.
  defp add(nil, other), do: other
  defp add(total, nil), do: total
  defp add(total, other), do: total + other

  # {watched, skipped} from one `played/` line, or nil for a line that is not one.
  defp read_play(path) do
    with {:ok, body} <- File.read(path),
         [watched, skipped | _] <- String.split(String.trim(body)),
         {watched, ""} <- Integer.parse(watched),
         {skipped, ""} <- Integer.parse(skipped) do
      {watched, skipped}
    else
      _ -> nil
    end
  end

  @doc """
  When laev last saw each position file change: `%{"tv-225634-s1e7" => 1790602387}`.

  This is the nearest thing there is to "when was this marked or finished". It is the time the
  change was noticed by a sync, so it can run a little behind the play itself; and an import
  stamps everything it brings in with the same moment.
  """
  def positions_at do
    with {:ok, body} <- File.read(Path.join(Laev.Scope.dir(), "sync.json")),
         {:ok, %{"positions" => positions}} when is_map(positions) <- Jason.decode(body) do
      for {name, %{"updated_at" => at, "deleted" => false}} <- positions,
          is_integer(at),
          into: %{} do
        {name, at}
      end
    else
      _ -> %{}
    end
  end

  # ── posters ────────────────────────────────────────────────────────

  @doc """
  A poster for each title, from the cards laev already holds — one file read, no requests.

  An anime is filed by its MyAnimeList id and the cards by TMDB's, so it goes through the
  cross-id map (already loaded by `build/0`) to find the show or film it belongs to. Anything
  with no card and anything that map cannot place has no poster, and the page draws its kind
  instead.
  """
  def posters(titles) do
    keyed =
      for t <- titles, key = card_key(t), into: %{} do
        {{t.type, t.tmdb_id}, key}
      end

    cards = Laev.Cards.get_many(keyed |> Map.values() |> Enum.uniq())

    for {title_key, card_key} <- keyed,
        card = cards[card_key],
        is_map(card),
        path = card["poster_path"],
        is_binary(path),
        into: %{} do
      {title_key, "https://image.tmdb.org/t/p/w154" <> path}
    end
  end

  defp card_key(%{type: "mal", tmdb_id: mal_id}) do
    case Laev.AnimeMap.tmdb(mal_id) do
      {"tv", id, _season} -> {"tv", id}
      {"movie", id} -> {"movie", id}
      _ -> nil
    end
  end

  defp card_key(%{type: type, tmdb_id: id}), do: {type, id}

  @doc "Titles last watched within `days` (all of them for `nil`), most time first."
  def within(titles, nil, _now), do: titles

  def within(titles, days, now) do
    cutoff = now - days * 86_400
    Enum.filter(titles, &(is_integer(&1.last_seen) and &1.last_seen >= cutoff))
  end

  @doc """
  What each season of a show holds: `%{{"tv", 110316} => %{1 => %{episodes: 8, marked: 8,
  seconds: 0}}}`.

  Laev's time is per title — a show is one number however many seasons it has — but the record
  it is derived from is one file per episode, named `tv-110316-s1e5`, and the file says which
  kind of time it is. A file holding "seen" is a hand mark, and its time is laev's estimate of
  the episode's runtime; a file holding a number is a position, and that episode was really
  played. So a season is described by both counts, and a season's share of a show can be worked
  out from the matching half rather than from episode numbers alone.

  That distinction is the whole point. Eight marked episodes and two test plays of nine minutes
  is ten episodes either way, and dividing a show's hours ten ways hands a fifth of eight marked
  episodes' runtime to the two that were barely touched.

  Entries numbered without a season (`tv-110316-e5`) and whole-show marks have no season to
  belong to, so they are not counted and their time stays with the title.
  """
  def season_episodes do
    dir = Path.join(Laev.Scope.dir(), "positions")

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            [_, type, id, season] <-
              [Regex.run(~r/^(tv|mal)-(\d+)-s(\d+)e\d+$/, name)] |> Enum.reject(&is_nil/1),
            reduce: %{} do
          acc ->
            key = {type, String.to_integer(id)}
            season = String.to_integer(season)
            one = episode(Path.join(dir, name))

            Map.update(acc, key, %{season => one}, fn seasons ->
              Map.update(seasons, season, one, &merge_episode(&1, one))
            end)
        end

      _ ->
        %{}
    end
  end

  # A position file is either a resume point in seconds or the word "seen".
  defp episode(path) do
    with {:ok, body} <- File.read(path),
         {seconds, _} when seconds > 0 <- Integer.parse(String.trim(body)) do
      %{episodes: 1, marked: 0, seconds: seconds}
    else
      _ -> %{episodes: 1, marked: 1, seconds: 0}
    end
  end

  defp merge_episode(a, b) do
    %{
      episodes: a.episodes + b.episodes,
      marked: a.marked + b.marked,
      seconds: a.seconds + b.seconds
    }
  end

  # ── days ───────────────────────────────────────────────────────────

  @doc "Seconds per day from every device's log, as `%{~D[2026-10-22] => 3600}`."
  def day_totals do
    dir = Path.join(Laev.Scope.dir(), "watched")

    dir
    |> Path.join("*.log")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, acc ->
      case File.read(path) do
        {:ok, body} -> add_log(acc, body)
        _ -> acc
      end
    end)
    |> Map.new(fn {date, seconds} -> {date, min(seconds, @day_cap)} end)
  end

  # `2026-10-22 5` per line — but a fused `2026-10-22 12026-10-22 2` is two entries.
  # Lazy digits end at the next date, whitespace, or the end.
  @entry ~r/(\d{4}-\d{2}-\d{2}) (\d+?)(?=\d{4}-\d{2}-\d{2}|\s|$)/

  @doc false
  def add_log(acc, body) do
    @entry
    |> Regex.scan(body)
    |> Enum.reduce(acc, fn [_, date, seconds], acc ->
      with {:ok, date} <- Date.from_iso8601(date),
           {n, ""} <- Integer.parse(seconds),
           true <- n <= @day_cap do
        Map.update(acc, date, n, &(&1 + n))
      else
        _ -> acc
      end
    end)
  end

  defp windows(days) do
    today = Days.today()

    for {id, label, n} <- [
          {:week, "7 days", 7},
          {:month, "30 days", 30},
          {:half_year, "6 months", 183},
          {:year, "12 months", 365}
        ] do
      seconds =
        for offset <- 0..(n - 1), reduce: 0 do
          acc -> acc + Map.get(days, Date.add(today, -offset), 0)
        end

      %{id: id, label: label, seconds: seconds}
    end
  end

  # {current streak ending today (or yesterday), longest} over the last year.
  defp streaks(days) do
    today = Days.today()
    list = for offset <- 364..0//-1, do: Map.get(days, Date.add(today, -offset), 0) > 0

    {longest, _} =
      Enum.reduce(list, {0, 0}, fn on?, {best, run} ->
        run = if on?, do: run + 1, else: 0
        {max(best, run), run}
      end)

    current =
      list
      |> Enum.reverse()
      |> then(fn [today_on | rest] -> if today_on, do: [true | rest], else: rest end)
      |> Enum.take_while(& &1)
      |> length()

    %{current: current, longest: longest}
  end

  @doc """
  A heatmap, GitHub-style: `weeks` whole Monday-to-Sunday columns ending with this
  one. Returns a list of weeks, each a list of 7 `{date, seconds | nil}` — `nil` for
  days that have not happened yet.
  """
  def heatmap(days, weeks) do
    today = Days.today()
    start = Date.add(today, -((weeks - 1) * 7 + (Date.day_of_week(today) - 1)))

    for w <- 0..(weeks - 1) do
      for d <- 0..6 do
        date = Date.add(start, w * 7 + d)
        {date, if(Date.compare(date, today) == :gt, do: nil, else: Map.get(days, date, 0))}
      end
    end
  end
end
