defmodule Roki.Stints do
  @moduledoc """
  Watching as sessions, read from laev's own tick log.

  Laev keeps `ticks/<device>.log` — one line per stretch of watching, the position key and the
  seconds it measured — and folds those lines into sessions (`Laev.Stints`, since 0.1.46).
  Everything that plays anything goes through `Laev.Position.record/2`, so the mpv script, the
  VLC poller and this site all land in one record, and a session assembled here is the same
  session the terminal app would assemble from the same lines.

  This site wrote its watching into the `stint` table for a day, beside the reader's reading.
  It does not any more, and should not: that would be the same watching counted twice, once by
  laev and once here. Reading stays in `stint` because the reader is this site's own; watching
  belongs to laev, which is where all of it happens.

  What is left here is the reading-back: laev's sessions keyed the way the rest of roki keys a
  title (`{"tv", 110_316}`), divided over local days, and dressed as `Stint.Record` structs for
  the day view that already draws the reader's sessions.
  """

  @prefix "watch:"

  @doc "The stint item for a title: `\"watch:tv/110316\"`."
  def item(%{type: type, tmdb_id: id}), do: "#{@prefix}#{type}/#{id}"
  def item(%{type: type, id: id}), do: "#{@prefix}#{type}/#{id}"

  @doc """
  Every watching session this account has, oldest first:
  `[%{key:, title:, started_at:, ended_at:, seconds:, keys:}]`.

  `keys` is laev's own position keys, so the episodes a session ran through are still in it:
  `["tv-110316-s1e1", "tv-110316-s1e2"]`.
  """
  def sessions(uuid) when is_binary(uuid) do
    case Roki.Laev.run(uuid, &read/0) do
      sessions when is_list(sessions) -> sessions
      _ -> []
    end
  end

  def sessions(_uuid), do: []

  defp read do
    titles = Laev.Titles.all()

    for s <- Laev.Stints.sessions(), key = parse(s.item) do
      %{
        key: key,
        title: Map.get(titles, s.item),
        started_at: s.started_at,
        ended_at: s.ended_at,
        seconds: s.seconds,
        keys: s.keys
      }
    end
  rescue
    _ -> []
  end

  @doc """
  Seconds watched per local day: `%{~D[2026-10-29] => 3600}`.

  A session that runs past midnight is divided between the days it touches, in proportion to
  how much of it falls in each — the honest answer when all that is known is "this much,
  between these two times".
  """
  def days(uuid, offset \\ 0) do
    for s <- sessions(uuid), {date, seconds} <- per_day(s, offset), reduce: %{} do
      acc -> Map.update(acc, date, seconds, &(&1 + seconds))
    end
  end

  @doc """
  The same, per title: `%{{"tv", 110_316} => %{~D[2026-10-29] => 3600}}`.

  What lets a title's own date keep only the time no day is known for, instead of claiming
  hours the log can already place.
  """
  def by_title(uuid, offset \\ 0) do
    for s <- sessions(uuid), {date, seconds} <- per_day(s, offset), reduce: %{} do
      acc ->
        Map.update(acc, s.key, %{date => seconds}, fn days ->
          Map.update(days, date, seconds, &(&1 + seconds))
        end)
    end
  end

  @doc """
  What was watched in the last `days`, longest first: `[%{key:, title:, seconds:, sessions:,
  episodes:, last:}]` — the exact figure for that window, because every second of it has a day.
  """
  def recent(uuid, days, offset \\ 0, today \\ nil) do
    from = Date.add(today || Date.utc_today(), -days)

    for s <- sessions(uuid), reduce: %{} do
      acc ->
        seconds =
          for {date, n} <- per_day(s, offset), Date.compare(date, from) != :lt, reduce: 0 do
            sum -> sum + n
          end

        if seconds > 0,
          do: Map.update(acc, s.key, one(s, seconds), &more(&1, s, seconds)),
          else: acc
    end
    |> Map.values()
    |> Enum.map(&%{&1 | episodes: MapSet.size(&1.episodes)})
    |> Enum.sort_by(& &1.seconds, :desc)
  end

  defp one(s, seconds) do
    %{
      key: s.key,
      title: s.title,
      seconds: seconds,
      sessions: 1,
      episodes: MapSet.new(s.keys),
      last: s.ended_at
    }
  end

  defp more(acc, s, seconds) do
    %{
      acc
      | seconds: acc.seconds + seconds,
        sessions: acc.sessions + 1,
        title: acc.title || s.title,
        episodes: MapSet.union(acc.episodes, MapSet.new(s.keys)),
        last: max(acc.last, s.ended_at)
    }
  end

  @doc """
  The watching sessions as `Stint.Record` structs, so the day view that already draws the
  reader's sessions can draw these beside them without knowing where they came from.

  Never persisted — laev's log is where they live, and a second copy here would be the same
  watching counted twice.
  """
  def records(uuid) do
    for s <- sessions(uuid) do
      {type, id} = s.key

      %Stint.Record{
        owner_id: uuid,
        item: "#{@prefix}#{type}/#{id}",
        started_at: DateTime.from_unix!(s.started_at),
        ended_at: DateTime.from_unix!(s.ended_at),
        seconds: s.seconds,
        meta: %{"title" => s.title, "episodes" => s.keys}
      }
    end
  end

  @doc "A title from laev's own key or from a stint item, or nil for anything that is not one."
  def parse(@prefix <> rest), do: parse(String.replace(rest, "/", "-"))

  def parse(key) when is_binary(key) do
    case Regex.run(~r/^(movie|tv|mal)-(\d+)$/, key) do
      [_, type, id] -> {type, String.to_integer(id)}
      _ -> nil
    end
  end

  def parse(_key), do: nil

  # A session's seconds spread over the local dates it touches, in proportion to its time in
  # each. Tracked seconds are not the same as elapsed time — a paused film still ends its
  # session later than it watched — so the split is of what was tracked, not of the clock.
  defp per_day(s, offset) do
    first = local_date(s.started_at, offset)
    last = local_date(s.ended_at, offset)

    if first == last do
      %{first => s.seconds}
    else
      elapsed = max(s.ended_at - s.started_at, 1)

      # A day the session only touches on the boundary gets nothing, and nothing is not a day
      # it was watched on: an empty slice is left out rather than written as a zero.
      for date <- Date.range(first, last),
          {day_start, day_end} = bounds(date, offset),
          share =
            div(
              s.seconds * max(min(s.ended_at, day_end) - max(s.started_at, day_start), 0),
              elapsed
            ),
          share > 0,
          into: %{} do
        {date, share}
      end
    end
  end

  defp bounds(date, offset) do
    start =
      date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix() |> Kernel.-(offset)

    {start, start + 86_400}
  end

  defp local_date(at, offset),
    do: at |> Kernel.+(offset) |> DateTime.from_unix!() |> DateTime.to_date()
end
