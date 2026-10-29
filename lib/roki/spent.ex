defmodule Roki.Spent do
  @moduledoc """
  Everything an account has spent time on, watched and read, as one list.

  The stats page used to be two: laev's measured watching on one side and the reader's own
  tally on the other, each with its own totals, its own windows and its own table. They answer
  the same question, so they are one thing here — a list of entries, each with a kind, the time
  on it, and when it was last touched. Everything the page shows is that list filtered and
  added up, so the big number is always the sum of the rows under it.

  **What a window means.** An entry is in the last 7 days if it was touched in the last 7 days,
  and it brings all of its time with it. So "7 days" reads as "what you were on this week, and
  how long you have spent on it", not "hours logged this week" — a series you have been on for
  a year counts its year.

  **When something counts.** Whatever this account says: the date set on the watched page where
  there is one, laev's last play otherwise, and for reading the day a series was last opened.
  `days/2` places the same entries on the same dates, so the heatmap and the list are two
  drawings of one thing rather than two sources that disagree.
  """

  @kinds [movie: "Films", tv: "Shows", anime: "Anime", manga: "Manga"]

  @ranges [
    {:week, "7 days", 7},
    {:month, "30 days", 30},
    {:year, "12 months", 365},
    {:all, "All time", nil}
  ]

  @doc "The kinds an entry can be, in the order the page lists them."
  def kinds, do: @kinds

  @doc "The windows the page offers: `{id, label, days}`, `days` nil for all time."
  def ranges, do: @ranges

  @doc "A range id from a URL, or `:all`."
  def range(value) do
    Enum.find_value(@ranges, :all, fn {id, _, _} -> Atom.to_string(id) == value && id end)
  end

  @doc "A kind id from a URL, or `:all`."
  def kind(value) do
    Enum.find_value(@kinds, :all, fn {id, _} -> Atom.to_string(id) == value && id end)
  end

  @doc """
  What was watched, from `Roki.Stats` data, as entries.

  `dates` is `Roki.Profile.watch_dates/1`: where this account has said when it watched
  something, that is when it counts. Laev knows when a title was last *played*, which for
  anything marked or backdated is a different thing — a film given a date in 2019 belongs in
  2019, and something played once while testing belongs wherever its owner put it, not in this
  week.

  `season_dates` is `Roki.Profile.season_dates/1`, and it splits a show. A season with a date
  of its own becomes an entry of its own, carrying its share of the show's time; what is left
  stays with the title. The share is by episodes watched — `stats.seasons` counts them, one
  file per episode — so a show whose first season is eight episodes and second is two gives
  the first four fifths of the hours.

  That share is proportional rather than measured: laev times a show as one number, and
  episodes of a show are close enough in length for the division to be fair. The shares are
  made to sum back to laev's figure exactly, so splitting a show never changes a total — it
  only moves time to the date it belongs under.
  """
  def watched(stats, dates \\ %{}, season_dates \\ %{})

  def watched(%{titles: titles} = stats, dates, season_dates) do
    seasons = Map.get(stats, :seasons, %{})

    Enum.flat_map(titles, fn t ->
      key = {t.type, t.id}
      at = Map.get(dates, key, t.last_seen)
      split(t, at, seasons[key], season_dates)
    end)
  end

  def watched(_, _dates, _season_dates), do: []

  # A show with no season dated, or nothing to divide by, is one entry as it always was.
  defp split(t, at, counts, season_dates) do
    dated =
      for {season, episodes} <- counts || %{},
          when_at = season_dates[{t.type, t.id, season}],
          do: {season, episodes, when_at}

    total_episodes = counts |> Kernel.||(%{}) |> Map.values() |> Enum.sum()

    if dated == [] or total_episodes == 0 do
      [entry(t, t.title, t.seconds, t.off, at)]
    else
      parts =
        for {season, episodes, when_at} <- Enum.sort(dated) do
          share = fn whole -> div(whole * episodes, total_episodes) end
          entry(t, "#{t.title} · S#{season}", share.(t.seconds), share.(t.off), when_at)
        end

      # Whatever the division left over stays with the title, so the show still adds up to
      # laev's own figure however its seasons are dated.
      rest =
        entry(
          t,
          t.title,
          t.seconds - Enum.sum(Enum.map(parts, & &1.seconds)),
          t.off - Enum.sum(Enum.map(parts, & &1.off)),
          at
        )

      if rest.seconds > 0, do: parts ++ [rest], else: parts
    end
  end

  defp entry(t, title, seconds, off, at) do
    %{
      kind: if(t.anime, do: :anime, else: String.to_existing_atom(t.type)),
      title: title,
      seconds: seconds,
      off: max(off, 0),
      at: at
    }
  end

  @doc "What was read, from the reader's own tally, as entries."
  def read(uuid) when is_binary(uuid) do
    for m <- Roki.Manga.Library.list_reading_stats(uuid) do
      on = m.reading_seconds_adjusted || m.reading_seconds || 0
      off = m.reading_seconds_offsite || 0

      %{
        kind: :manga,
        title: m.title,
        seconds: on + off,
        off: off,
        at: m.updated_at && DateTime.to_unix(DateTime.from_naive!(m.updated_at, "Etc/UTC"))
      }
    end
  end

  @doc "Longest first."
  def sort(entries), do: Enum.sort_by(entries, & &1.seconds, :desc)

  @doc "The entries touched within `days`; all of them for `nil`."
  def within(entries, nil, _now), do: entries

  def within(entries, days, now) do
    cutoff = now - days * 86_400
    Enum.filter(entries, &(is_integer(&1.at) and &1.at >= cutoff))
  end

  @doc "The entries of one kind; all of them for `:all`."
  def of_kind(entries, :all), do: entries
  def of_kind(entries, kind), do: Enum.filter(entries, &(&1.kind == kind))

  @doc "Seconds across these entries."
  def total(entries), do: entries |> Enum.map(& &1.seconds) |> Enum.sum()

  @doc "Seconds per kind, every kind present as a key."
  def by_kind(entries) do
    for {id, _} <- @kinds, into: %{}, do: {id, total(of_kind(entries, id))}
  end

  # ── the day-by-day half, which is exact ────────────────────────────

  @doc """
  Seconds per day, as the heatmap draws it.

  Watching is placed on the date this account says it watched the thing — the same date the
  list counts it under, so the two agree and a title given a date lands where it was put rather
  than on the day a device happened to play it. A whole series therefore arrives in one day,
  which is what a date is: an answer about a title, not about an evening.

  Reading keeps its own day-by-day log, because it has one. Lumping a series onto the day it
  was last opened would throw away months of real days to make the two halves symmetrical,
  which is a bad trade.
  """
  def days(watched, reading_activity) do
    watched_days =
      for e <- watched, is_integer(e.at), reduce: %{} do
        acc ->
          date = e.at |> DateTime.from_unix!() |> DateTime.to_date()
          Map.update(acc, date, e.seconds, &(&1 + e.seconds))
      end

    read_days =
      for {date, rows} <- reading_activity || %{}, into: %{} do
        {date, rows |> Enum.map(&(&1.seconds || 0)) |> Enum.sum()}
      end

    Map.merge(watched_days, read_days, fn _date, a, b -> a + b end)
  end

  @doc "Seconds in each of the trailing windows: `[%{id:, label:, seconds:}]`."
  def windows(days, today) do
    for {id, label, n} <- @ranges, n != nil do
      seconds =
        for offset <- 0..(n - 1), reduce: 0 do
          acc -> acc + Map.get(days, Date.add(today, -offset), 0)
        end

      %{id: id, label: label, seconds: seconds}
    end
  end

  @doc "`%{current:, longest:}` runs of days with anything on them, over the last year."
  def streak(days, today) do
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
end
