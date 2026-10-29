defmodule Roki.Stints do
  @moduledoc """
  Watching, recorded as stints — the same way the reader records reading.

  `Stint` has done this for the reader all along: a tick says "this much time, on this thing,
  now", and sessions assemble themselves — within the gap it extends the one in progress, after
  a longer silence it opens a new one. Session *ends* are unobservable (tabs close, phones
  lock), so they are inferred rather than reported, and the result distinguishes one two-hour
  evening from six three-minute peeks.

  Watching had nothing like it. Laev keeps one number per title plus a day log with no titles
  in it, which can say how much and never when — so a window over watching had to carry a
  title's whole history in on the strength of one evening, and a title given a date arrived in
  one lump on that day.

  The item key follows the reader's: `"manga:mangadex/one-piece"` becomes `"watch:tv/110316"` —
  the title, not the episode, because a run of episodes in one evening is one session, and the
  episode goes in `meta` exactly as the chapter does. Which episodes a stint covered is read
  back the way the reader reads chapters: by intersecting the finishes recorded beside it.

  This is new, so it knows only what has been watched here since it was added. Laev's own
  totals remain the answer for everything older, which is why these days are read alongside
  them rather than instead of them.
  """

  import Ecto.Query

  alias Roki.Repo
  alias Stint.Record

  @prefix "watch:"

  @doc "The stint item for a play context: `\"watch:tv/110316\"`."
  def item(%{type: type, tmdb_id: id}), do: "#{@prefix}#{type}/#{id}"
  def item(%{type: type, id: id}), do: "#{@prefix}#{type}/#{id}"

  @doc """
  Record `seconds` of watching. The episode and title ride along in `meta`, as the reader's
  chapter does, so a day view can name what was on without a second query.
  """
  def track(uuid, ctx, seconds)

  def track(uuid, %{type: _, tmdb_id: _} = ctx, seconds)
      when is_binary(uuid) and is_integer(seconds) and seconds > 0 do
    Stint.track(uuid, item(ctx), seconds, meta: meta(ctx))
    :ok
  rescue
    _ -> :ok
  end

  def track(_uuid, _ctx, _seconds), do: :ok

  defp meta(ctx) do
    %{"title" => ctx[:title], "season" => ctx[:season], "episode" => ctx[:episode]}
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc "Every watching stint this account has, oldest first."
  def all(uuid) when is_binary(uuid) do
    from(s in Record,
      where: s.owner_id == ^uuid and like(s.item, ^(@prefix <> "%")),
      order_by: [asc: s.started_at]
    )
    |> Repo.all()
  end

  def all(_uuid), do: []

  @doc """
  Seconds watched per local day: `%{~D[2026-10-29] => 3600}`.

  One query rather than one per day, which is what a year of heatmap needs. A stint that runs
  past midnight is divided between the days it touches, in proportion to how much of it falls
  in each — the honest answer when all that is known is "this much, between these two times".
  """
  def days(uuid, offset \\ 0) do
    for s <- all(uuid), {date, seconds} <- per_day(s, offset), reduce: %{} do
      acc -> Map.update(acc, date, seconds, &(&1 + seconds))
    end
  end

  @doc """
  The same, per title: `%{{"tv", 110_316} => %{~D[2026-10-29] => 3600}}`.

  What lets a title's own date keep only the time no day is known for, instead of claiming
  hours the log can already place.
  """
  def by_title(uuid, offset \\ 0) do
    for s <- all(uuid), key = parse(s.item), {date, seconds} <- per_day(s, offset), reduce: %{} do
      acc ->
        Map.update(acc, key, %{date => seconds}, fn days ->
          Map.update(days, date, seconds, &(&1 + seconds))
        end)
    end
  end

  @doc """
  What was watched in the last `days`, longest first: `[%{key:, title:, seconds:, sessions:,
  last:}]` — the exact figure for that window, because every second of it has a day.
  """
  def recent(uuid, days, offset \\ 0, today \\ nil) do
    from = Date.add(today || Date.utc_today(), -days)

    for s <- all(uuid), key = parse(s.item), reduce: %{} do
      acc ->
        seconds =
          for {date, n} <- per_day(s, offset), Date.compare(date, from) != :lt, reduce: 0 do
            sum -> sum + n
          end

        if seconds > 0 do
          Map.update(
            acc,
            key,
            %{key: key, title: s.meta["title"], seconds: seconds, sessions: 1, last: s.ended_at},
            fn e ->
              %{
                e
                | seconds: e.seconds + seconds,
                  sessions: e.sessions + 1,
                  title: e.title || s.meta["title"],
                  last:
                    if(DateTime.compare(s.ended_at, e.last) == :gt, do: s.ended_at, else: e.last)
              }
            end
          )
        else
          acc
        end
    end
    |> Map.values()
    |> Enum.sort_by(& &1.seconds, :desc)
  end

  @doc """
  Which episodes a stint covered: the finishes recorded inside its window, as
  `[%{season:, episode:, title:}]`.

  The reader reads chapters out of a stint this way — the stint says when, the finish events say
  what — and keeping to it means a stint is still one session however many episodes it spans.
  """
  def episodes_in(uuid, %Record{} = stint) do
    {type, id} = parse(stint.item)

    from(a in "roki_activity",
      where: a.user_uuid == type(^uuid, Ecto.UUID),
      where: a.kind == "finished" and a.type == ^type and a.tmdb_id == ^id,
      where: a.at >= ^naive(stint.started_at) and a.at <= ^naive(stint.ended_at),
      order_by: [asc: a.at],
      select: %{season: a.season, episode: a.episode, title: a.title}
    )
    |> Repo.all()
  end

  @doc "A title from a stint item, or nil for anything that is not one."
  def parse(@prefix <> rest) do
    case String.split(rest, "/", parts: 2) do
      [type, id] -> with {n, ""} <- Integer.parse(id), do: {type, n}, else: (_ -> nil)
      _ -> nil
    end
  end

  def parse(_item), do: nil

  # A stint's seconds spread over the local dates it touches, in proportion to its time in
  # each. Tracked seconds are not the same as elapsed time — a paused film still ends its
  # stint later than it watched — so the split is of what was tracked, not of the clock.
  defp per_day(%Record{} = s, offset) do
    first = local_date(s.started_at, offset)
    last = local_date(s.ended_at, offset)

    if first == last do
      %{first => s.seconds}
    else
      elapsed = max(DateTime.diff(s.ended_at, s.started_at), 1)

      for date <- Date.range(first, last), into: %{} do
        {day_start, day_end} = bounds(date, offset)

        from =
          if DateTime.compare(s.started_at, day_start) == :gt, do: s.started_at, else: day_start

        to = if DateTime.compare(s.ended_at, day_end) == :lt, do: s.ended_at, else: day_end
        {date, div(s.seconds * max(DateTime.diff(to, from), 0), elapsed)}
      end
    end
  end

  defp bounds(date, offset) do
    start = date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.add(-offset, :second)
    {start, DateTime.add(start, 86_400, :second)}
  end

  defp local_date(dt, offset), do: dt |> DateTime.add(offset, :second) |> DateTime.to_date()

  defp naive(dt), do: dt |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
end
