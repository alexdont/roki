defmodule Roki.Spent do
  @moduledoc """
  Everything an account has spent time on, watched and read, as one list.

  The stats page used to be two: laev's measured watching on one side and the reader's own
  tally on the other, each with its own totals, its own windows and its own table. They answer
  the same question, so they are one thing here — a list of entries, each with a kind, the time
  on it, and when it was last touched. Everything the page shows is that list filtered and
  added up, so the big number is always the sum of the rows under it.

  **What a window means.** An entry is in the last 7 days if it was *touched* in the last 7
  days, and it brings all of its time with it. That is laev's own rule, kept because the two
  sides can only agree on it: reading is logged per day, watching is not. So "7 days" reads as
  "what you were on this week, and how long you have spent on it", not "hours logged this
  week". The day-by-day totals that feed the heatmap are exact; these are not, and the page
  says so.
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
  """
  def watched(stats, dates \\ %{})

  def watched(%{titles: titles}, dates) do
    for t <- titles do
      %{
        kind: if(t.anime, do: :anime, else: String.to_existing_atom(t.type)),
        title: t.title,
        seconds: t.seconds,
        off: t.off,
        at: Map.get(dates, {t.type, t.id}, t.last_seen)
      }
    end
  end

  def watched(_, _dates), do: []

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
  Watching's seconds-per-day merged with reading's, as `%{~D[2026-10-22] => 3600}`.

  Both sides log a day at a time, so unlike the entries above this is the real thing: what the
  heatmap and the window totals beside it are drawn from.
  """
  def days(watch_days, reading_activity) do
    read_days =
      for {date, rows} <- reading_activity || %{}, into: %{} do
        {date, rows |> Enum.map(&(&1.seconds || 0)) |> Enum.sum()}
      end

    Map.merge(watch_days || %{}, read_days, fn _date, a, b -> a + b end)
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
