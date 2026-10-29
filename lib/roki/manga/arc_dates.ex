defmodule Roki.Manga.ArcDates do
  @moduledoc """
  Dating the parts of a series that were read before the site saw them.

  A show's seasons can be given dates of their own, so watching the second season
  this month does not move the first one's hours here with it. A long series has the
  same problem and a worse version of it: most reading time on this account was
  entered by hand — 421 hours of 549 when this was written — and a hand-entered
  figure has no day at all, so all of it sits in "all time" and in no window.

  An arc with a date fixes that for its share. The share is by chapters: an arc
  covering twenty of the hundred chapters read takes a fifth of the hours that have
  no day of their own, and that fifth counts on the date given. What is left stays
  with the series, so dating an arc never changes a total — it only moves time to
  when it happened.

  **Only the off-site figure is split.** On-site reading is logged day by day and is
  already in the right place; splitting it as well would count those hours twice.

  Volumes work the same way and are offered when a series has volumes but no arcs —
  the same `position` + chapter span, so the arithmetic does not care which it is.
  """

  import Ecto.Query

  alias Roki.Manga.Fabledex
  alias Roki.Manga.Library.MangaArcDate
  alias Roki.Repo

  @kinds ["arc", "volume"]

  @doc "The dates set for one series, as `%{{kind, position} => Date}`."
  def get(user_uuid, source, slug) do
    MangaArcDate
    |> where([d], d.user_id == type(^user_uuid, Ecto.UUID))
    |> where(source: ^source, slug: ^slug)
    |> select([d], {d.kind, d.position, d.at})
    |> Repo.all()
    |> Map.new(fn {kind, position, at} -> {{kind, position}, NaiveDateTime.to_date(at)} end)
  end

  @doc """
  Set or clear one arc's date. A nil date deletes the row — the arc goes back to
  counting with the rest of the series.
  """
  def set(user_uuid, source, slug, kind, position, date)

  def set(user_uuid, source, slug, kind, position, nil) when kind in @kinds do
    MangaArcDate
    |> where([d], d.user_id == type(^user_uuid, Ecto.UUID))
    |> where(source: ^source, slug: ^slug, kind: ^kind, position: ^position)
    |> Repo.delete_all()

    :ok
  end

  def set(user_uuid, source, slug, kind, position, %Date{} = date) when kind in @kinds do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all(
      MangaArcDate,
      [
        %{
          user_id: user_uuid,
          source: source,
          slug: slug,
          kind: kind,
          position: position,
          # Noon, as the watched page's dates are, so a timezone cannot
          # push a date onto the day before.
          at: NaiveDateTime.new!(date, ~T[12:00:00]),
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:at, :updated_at]},
      conflict_target: [:user_id, :source, :slug, :kind, :position]
    )

    :ok
  end

  def set(_user_uuid, _source, _slug, _kind, _position, _date), do: :ok

  @doc """
  The dated pieces of every series this account reads, for the stats page:
  `%{{source, slug} => [%{title:, seconds:, at: unix}]}`.

  `rows` is `Roki.Manga.Library.list_reading_stats/1`. Series with no dated arc are
  absent, so the common case costs one query and no arithmetic.
  """
  def parts(user_uuid, rows) do
    dated = all(user_uuid)
    keyed = Map.new(rows, &{{&1.source, &1.slug}, &1})

    pairs =
      for {{source, slug} = key, dates} <- dated, row = keyed[key] do
        {key, split(row, Fabledex.get(source, slug), dates)}
      end

    pairs |> Enum.reject(fn {_key, parts} -> parts == [] end) |> Map.new()
  end

  # Every date this account has set, grouped by series.
  defp all(user_uuid) do
    MangaArcDate
    |> where([d], d.user_id == type(^user_uuid, Ecto.UUID))
    |> select([d], {d.source, d.slug, d.kind, d.position, d.at})
    |> Repo.all()
    |> Enum.group_by(fn {source, slug, _, _, _} -> {source, slug} end, fn {_, _, kind, pos, at} ->
      {kind, pos, at}
    end)
  end

  @doc """
  The arcs and volumes of a series that can be given a date, in the shape the
  dialog on the details page renders: `%{kind:, position:, title:, from:, to:,
  chapters:, seconds:, at:}`, where `seconds` is what that part would carry and
  `at` the date already set, if any.

  Arcs when the series has them, volumes otherwise — one list, because dating both
  would divide the same hours twice.
  """
  def datable(user_uuid, %{} = row, story) do
    dates = get(user_uuid, row.source, row.slug)
    read = chapters_read(row)
    off = row.reading_seconds_offsite || 0

    {kind, segments} =
      case Fabledex.arcs(story) do
        [] -> {"volume", Fabledex.volumes(story)}
        arcs -> {"arc", arcs}
      end

    for seg <- segments, is_integer(seg.from), is_integer(seg.to) do
      chapters = covered(seg, read)

      %{
        kind: kind,
        position: seg.position,
        title: label(kind, seg),
        from: seg.from,
        to: seg.to,
        chapters: chapters,
        seconds: share(off, chapters, read),
        at: dates[{kind, seg.position}]
      }
    end
  end

  def datable(_user_uuid, _row, _story), do: []

  defp split(row, story, dates) do
    read = chapters_read(row)
    off = row.reading_seconds_offsite || 0

    by_key =
      Map.new(
        Enum.map(Fabledex.arcs(story), &{{"arc", &1.position}, {"arc", &1}}) ++
          Enum.map(Fabledex.volumes(story), &{{"volume", &1.position}, {"volume", &1}})
      )

    parts =
      for {kind, position, at} <- dates,
          {^kind, seg} = Map.get(by_key, {kind, position}, {kind, nil}),
          seg != nil,
          chapters = covered(seg, read),
          seconds = share(off, chapters, read),
          seconds > 0 do
        %{
          title: "#{row.title} · #{label(kind, seg)}",
          seconds: seconds,
          at: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
        }
      end

    # Dating both an arc and a volume over the same chapters would hand out the
    # same hours twice. Nothing in the UI offers both, but the sum is capped
    # rather than trusted.
    clamp(parts, off, [])
  end

  defp clamp([], _left, acc), do: Enum.reverse(acc)

  defp clamp([part | rest], left, acc) do
    seconds = min(part.seconds, left)

    if seconds > 0 do
      clamp(rest, left - seconds, [%{part | seconds: seconds} | acc])
    else
      clamp(rest, left, acc)
    end
  end

  defp share(_off, _chapters, read) when not is_integer(read) or read <= 0, do: 0
  defp share(off, chapters, read), do: div(off * max(chapters, 0), read)

  defp label("volume", seg), do: seg.title
  defp label(_arc, seg), do: seg.title || "Arc #{seg.position}"

  # How much of an arc has actually been read. An arc beyond the current chapter
  # contributes nothing; the one in progress contributes the part reached.
  defp covered(%{from: from, to: to}, read)
       when is_integer(from) and is_integer(to) and is_integer(read) do
    max(0, min(to, read) - from + 1)
  end

  defp covered(_seg, _read), do: 0

  defp chapters_read(%{last_chapter: chapter}) when is_binary(chapter) do
    case Integer.parse(chapter) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp chapters_read(_row), do: nil
end
