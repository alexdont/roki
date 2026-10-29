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
  there is one, laev's last play otherwise, and for reading the last day the log says it was
  read.

  **A window holds what is known, and says how well it is known.** Reading is logged day by
  day, and watching has been too since it started keeping sessions, so for both of those a
  window holds exactly what those days hold. What is left is the watching from before the
  sessions and from the terminal app: one number per title, so the window holds those titles
  whole. The page says which is which, and a title crosses from one to the other the first
  time it is watched with the sessions running.
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
  stays with the title.

  **The share is taken from the matching half.** Laev times a show as one number, but it knows
  per episode whether that episode was marked by hand or really played (`stats.seasons`). A
  marked episode's time is laev's estimate of its runtime, so the marked hours divide by marked
  episodes; a played episode has a real position, so the measured hours divide by those
  positions. Mixing the two is how a show with eight marked episodes and two nine-minute test
  plays handed the second season two hours it never had.

  The shares are made to sum back to laev's figure exactly, so splitting a show never changes
  a total — it only moves time to the date it belongs under.
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
    counts = counts || %{}

    dated =
      for {season, info} <- counts,
          when_at = season_dates[{t.type, t.id, season}],
          do: {season, info, when_at}

    marked = counts |> Map.values() |> Enum.map(& &1.marked) |> Enum.sum()
    positions = counts |> Map.values() |> Enum.map(& &1.seconds) |> Enum.sum()
    measured = max(t.seconds - t.off, 0)

    parts =
      for {season, info, when_at} <- Enum.sort(dated),
          off = portion(t.off, info.marked, marked),
          seconds = off + portion(measured, info.seconds, positions),
          seconds > 0 do
        entry(t, "#{t.title} · S#{season}", seconds, off, when_at)
      end

    if parts == [] do
      [entry(t, t.title, t.seconds, t.off, at)]
    else
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

  defp portion(_whole, _part, 0), do: 0
  defp portion(whole, part, total), do: div(whole * part, total)

  defp entry(t, title, seconds, off, at) do
    %{
      kind: if(t.anime, do: :anime, else: String.to_existing_atom(t.type)),
      # Laev's own key for the thing, so an entry can be matched against what the day-by-day
      # log knows about it. A show split by season keeps the show's key, which is what it is.
      key: {t.type, t.id},
      title: title,
      # The title without the season it was split into, for when the sessions speak for the
      # whole thing and the split has nothing left to say.
      base: t.title,
      poster: t[:poster],
      seconds: seconds,
      off: max(off, 0),
      at: at
    }
  end

  @doc """
  What was read, as entries, already narrowed to the window.

  Reading is the one half that is logged day by day, so a window over it is the real thing
  rather than a title's whole history carried in because it was touched. That matters: a series
  read over months, with hours of off-site time entered by hand, was landing its entire total
  in "the last 30 days" on the strength of one chapter.

  All time is the whole tally, on-site and off, since off-site time is a figure with no day
  attached and belongs nowhere else. A window is only what the log holds for those days.

  The date an entry counts under is the last day it was actually read, not when its row was
  last written — an import or a cover repair touches a row without anyone reading anything.

  `arcs` is `Roki.Manga.ArcDates.parts/2`, and it splits a series the way `season_dates` splits
  a show: an arc given a date of its own becomes an entry of its own, carrying its share of the
  hours that have no day attached, and what is left stays with the series. So an account that
  read the first eighty chapters years ago, off this site, can say so — and those hours stop
  arriving in this month along with the chapter it read yesterday.
  """
  def read(rows, activity, days, now \\ nil, arcs \\ %{})

  def read(rows, activity, nil, _now, arcs) do
    last = last_read(activity)

    series =
      for m <- rows do
        on = m.reading_seconds_adjusted || m.reading_seconds || 0
        off = m.reading_seconds_offsite || 0
        dated = Map.get(arcs, {m.source, m.slug}, [])
        moved = dated |> Enum.map(& &1.seconds) |> Enum.sum()

        %{
          kind: :manga,
          key: {m.source, m.slug},
          title: m.title,
          base: m.title,
          seconds: on + off - moved,
          off: off - moved,
          at: last[{m.source, m.slug}] || naive_unix(m.updated_at)
        }
      end

    Enum.filter(series, &(&1.seconds > 0)) ++ arc_entries(arcs)
  end

  def read(rows, activity, days, now, arcs) do
    cutoff = Date.add(today(now), -days)

    windowed =
      for {date, items} <- activity || %{}, Date.compare(date, cutoff) != :lt, do: {date, items}

    seconds =
      for {_date, items} <- windowed, i <- items, reduce: %{} do
        acc -> Map.update(acc, {i.source, i.slug}, i.seconds || 0, &(&1 + (i.seconds || 0)))
      end

    last = last_read(windowed)
    titles = Map.new(rows, &{{&1.source, &1.slug}, &1.title})

    logged =
      for {key, s} <- seconds, s > 0 do
        %{
          kind: :manga,
          key: key,
          title: titles[key] || elem(key, 1),
          seconds: s,
          off: 0,
          at: last[key]
        }
      end

    from = cutoff |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

    logged ++ Enum.filter(arc_entries(arcs), &(is_integer(&1.at) and &1.at >= from))
  end

  # A dated arc is an entry in its own right, with its date and its share.
  defp arc_entries(arcs) do
    for {key, parts} <- arcs, p <- parts do
      %{
        kind: :manga,
        key: key,
        title: p.title,
        base: p.title,
        seconds: p.seconds,
        off: p.seconds,
        at: p.at
      }
    end
  end

  # The last day each series was read, as a unix time.
  defp last_read(activity) do
    for {date, items} <- activity || %{}, i <- items, reduce: %{} do
      acc ->
        at = date |> DateTime.new!(~T[12:00:00], "Etc/UTC") |> DateTime.to_unix()
        Map.update(acc, {i.source, i.slug}, at, &max(&1, at))
    end
  end

  defp today(nil), do: Date.utc_today()
  defp today(now), do: now |> DateTime.from_unix!() |> DateTime.to_date()

  defp naive_unix(nil), do: nil
  defp naive_unix(at), do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  @doc "Longest first."
  def sort(entries), do: Enum.sort_by(entries, & &1.seconds, :desc)

  @doc "The entries touched within `days`; all of them for `nil`."
  def within(entries, nil, _now), do: entries

  def within(entries, days, now) do
    cutoff = now - days * 86_400
    Enum.filter(entries, &(is_integer(&1.at) and &1.at >= cutoff))
  end

  @doc """
  The entries in a window, measured where they can be and estimated where they cannot.

  `logged` is `Roki.Stints.by_title/2`. A title it knows is one whose watching was recorded
  session by session, so the window holds **exactly** the seconds those sessions put in it —
  nothing if there were none, which is the honest answer and the one a tally can never give.
  A title it does not know is older than the sessions, or was watched in the terminal app, and
  for those the window still holds the title whole: all that is known is that it was touched
  in here somewhere.

  The two rules live side by side on purpose, and the page says which is which. Nothing had to
  be switched over on a date: a title moves from the second rule to the first the first time it
  is watched with the sessions running, so the page grows exact by itself.

  A measured title is one entry whatever its seasons are dated — a season's date places history
  that has no day of its own, and this has days.
  """
  def narrow(entries, days, now, logged \\ %{})

  def narrow(entries, nil, _now, _logged), do: entries

  def narrow(entries, days, now, logged) do
    from = Date.add(today(now), -days)
    {measured, rest} = Enum.split_with(entries, &Map.has_key?(logged, &1[:key]))

    exact =
      for {key, group} <- Enum.group_by(measured, & &1.key),
          by_day = Map.get(logged, key, %{}),
          within_window = for({date, n} <- by_day, Date.compare(date, from) != :lt, do: {date, n}),
          seconds = within_window |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
          seconds > 0 do
        first = hd(group)

        %{
          kind: first.kind,
          key: key,
          title: first[:base] || first.title,
          base: first[:base] || first.title,
          poster: first[:poster],
          seconds: seconds,
          off: 0,
          at: within_window |> Enum.map(&elem(&1, 0)) |> Enum.max() |> noon()
        }
      end

    exact ++ within(rest, days, now)
  end

  defp noon(date), do: date |> DateTime.new!(~T[12:00:00], "Etc/UTC") |> DateTime.to_unix()

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
  which is a bad trade. A dated arc is the exception, and for the same reason a watched title
  is: hours with no day of their own land on the day they were given.

  `logged` is `Roki.Stints.by_title/2` — watching that *does* have days of its own, because it
  happened here and the player said so as it went. Those hours are placed where they happened,
  and only what the log cannot account for falls back to the lump. Everything watched before
  that log existed, and everything watched in the terminal app, is still a lump; this is the
  half that stops being one.
  """
  def days(watched, reading_activity, arcs \\ %{}, logged \\ %{}) do
    known =
      for {_key, by_day} <- logged, {date, seconds} <- by_day, reduce: %{} do
        acc -> add(acc, date, seconds)
      end

    left = Map.new(logged, fn {key, by_day} -> {key, Enum.sum(Map.values(by_day))} end)

    # What the log already accounts for is not placed again: a title's own date keeps only the
    # time no day is known for. A show split across seasons spends that allowance in order, so
    # the two sides cannot both claim the same hour.
    {lumped, _left} =
      Enum.reduce(watched ++ arc_entries(arcs), {%{}, left}, fn e, {acc, left} ->
        take = min(Map.get(left, e[:key], 0), e.seconds)
        rest = e.seconds - take

        acc =
          if is_integer(e.at) and rest > 0 do
            add(acc, e.at |> DateTime.from_unix!() |> DateTime.to_date(), rest)
          else
            acc
          end

        {acc, Map.update(left, e[:key], 0, &(&1 - take))}
      end)

    read_days =
      for {date, rows} <- reading_activity || %{}, into: %{} do
        {date, rows |> Enum.map(&(&1.seconds || 0)) |> Enum.sum()}
      end

    known
    |> Map.merge(lumped, fn _date, a, b -> a + b end)
    |> Map.merge(read_days, fn _date, a, b -> a + b end)
  end

  defp add(acc, date, seconds), do: Map.update(acc, date, seconds, &(&1 + seconds))

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
