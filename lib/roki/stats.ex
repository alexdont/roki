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

  @doc """
  The headline totals for the shelf's one-line strip, kept ten minutes — the shelf is
  opened far more often than the numbers change, and measuring is real work. The full
  page uses `for_user/1` and is always live.

  `build/0` for a user, under a small per-user budget — the first measurement is a
  burst of TMDB lookups, and nothing should be able to repeat it in a loop.
  """
  def summary(uuid) do
    Roki.TTLCache.fetch({:stats_summary, uuid}, 10 * 60, fn ->
      with {:ok, s} <- for_user(uuid), do: {:ok, %{totals: s.totals}}
    end)
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

      {:ok,
       %{
         totals: Map.drop(s, [:titles]),
         titles: Enum.map(s.titles, &title(&1, seen)),
         tally: Shelf.tally(),
         days: days,
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

  defp title(t, seen) do
    %{
      type: t.type,
      id: t.tmdb_id,
      title: t.title,
      seconds: t.seconds,
      off: t.off,
      anime: t.type == "mal",
      last_seen: seen[{t.type, t.tmdb_id}]
    }
  end

  @doc "Titles last watched within `days` (all of them for `nil`), most time first."
  def within(titles, nil, _now), do: titles

  def within(titles, days, now) do
    cutoff = now - days * 86_400
    Enum.filter(titles, &(is_integer(&1.last_seen) and &1.last_seen >= cutoff))
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
