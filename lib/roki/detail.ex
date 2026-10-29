defmodule Roki.Detail do
  @moduledoc """
  Everything recorded about one title or one series, for the stats page's popup.

  The list says how long and which kind. This is the other half: what was measured and what was
  only known, when it was started, last watched and marked, the sessions it was watched in, and
  which episodes those were. Nothing here is worked out afresh — every figure is something laev
  or the reader already holds, read back — and a date that is not recorded is nil rather than
  guessed, so the popup can say "not recorded" instead of inventing one.

  **Where the dates come from**, because they are not all the same kind of fact:

    * a *session* date comes from laev's tick log (since laev 0.1.46) and is when it happened;
    * a *marked* date comes from laev's sync record of when a position file last changed, which is
      when the change was noticed — a little behind the event, and the same instant for everything
      an import brought in;
    * for reading, the started and completed dates are the reader's own milestones, which the
      owner can edit.
  """

  import Ecto.Query

  alias Roki.Manga.Library.{LibraryEvent, ReadingActivity, SavedManga}
  alias Roki.{Repo, Stats}

  @sessions_shown 8

  # ── watching ───────────────────────────────────────────────────────

  @doc """
  What laev holds about a film, show or anime: `{"movie", 603}`, `{"tv", 110316}`,
  `{"mal", 51553}`.
  """
  def watching(uuid, {type, id} = key) when is_binary(type) and is_integer(id) do
    base = "#{type}-#{id}"

    Roki.Laev.run(uuid, fn ->
      dir = Laev.Scope.dir()
      changed = Stats.positions_at()

      episodes =
        dir
        |> Path.join("positions")
        |> File.ls()
        |> case do
          {:ok, names} -> for n <- names, n == base or String.starts_with?(n, base <> "-"), do: n
          _ -> []
        end
        |> Enum.map(&episode(&1, base, type, dir, changed))
        |> Enum.sort_by(& &1.order)

      sessions = sessions(base)
      played = Enum.filter(episodes, &(&1.timed > 0))
      finished_plays = for e <- played, e.state == :finished, e.changed_at, do: e.changed_at

      %{
        kind: :watching,
        key: key,
        episodes: episodes,
        timed: sum(episodes, :timed),
        skipped: skipped(episodes, :believed),
        unsure: sum_where(episodes, &(&1.skipped != nil and not &1.believed?), :skipped),
        marked_count: Enum.count(episodes, &(&1.state == :marked and &1.name != base)),
        played_count: length(played),
        sessions: sessions |> Enum.reverse() |> Enum.take(@sessions_shown),
        session_count: length(sessions),
        longest: sessions |> Enum.map(& &1.seconds) |> Enum.max(fn -> 0 end),
        started: started_watching(sessions, finished_plays),
        last: last_watched(sessions, finished_plays),
        marked: marked(episodes, base),
        your_date: Roki.Profile.watch_dates(uuid)[key]
      }
    end)
  end

  defp episode(name, base, type, dir, changed) do
    {watched, skipped} = play(Path.join([dir, "played", name]))

    %{
      name: name,
      label: label(name, base, type),
      order: order(name, base),
      state: state(Path.join([dir, "positions", name])),
      timed: watched,
      skipped: skipped,
      changed_at: changed[name],
      believed?: Stats.believable?(changed[name])
    }
  end

  # {watched, skipped} from a `played/` line; {0, nil} when nothing was measured.
  defp play(path) do
    with {:ok, body} <- File.read(path),
         [w, s | _] <- String.split(String.trim(body)),
         {w, ""} <- Integer.parse(w),
         {s, ""} <- Integer.parse(s) do
      {w, s}
    else
      _ -> {0, nil}
    end
  end

  defp state(path) do
    case File.read(path) do
      {:ok, body} ->
        case String.trim(body) do
          "done" -> :finished
          "seen" -> :marked
          n -> with {secs, ""} <- Integer.parse(n), do: {:partway, secs}, else: (_ -> :marked)
        end

      _ ->
        :marked
    end
  end

  defp label(name, name, "movie"), do: "The film"
  defp label(name, name, _type), do: "The whole show"

  defp label(name, base, _type) do
    case Regex.run(~r/^#{Regex.escape(base)}-s(\d+)e(\d+)$/, name) do
      [_, s, e] -> "S#{s} E#{e}"
      _ -> episode_label(name, base)
    end
  end

  defp episode_label(name, base) do
    case Regex.run(~r/^#{Regex.escape(base)}-e(\d+)$/, name) do
      [_, e] -> "Episode #{e}"
      _ -> String.replace_prefix(name, base <> "-", "")
    end
  end

  # The whole-title mark first, then seasons and episodes in order.
  defp order(name, name), do: {0, 0}

  defp order(name, base) do
    case Regex.run(~r/^#{Regex.escape(base)}-(?:s(\d+))?e(\d+)$/, name) do
      [_, "", e] -> {0, String.to_integer(e)}
      [_, s, e] -> {String.to_integer(s), String.to_integer(e)}
      _ -> {9999, 0}
    end
  end

  defp sum(list, field), do: list |> Enum.map(&Map.get(&1, field)) |> Enum.sum()

  defp sum_where(list, pred, field),
    do: list |> Enum.filter(pred) |> Enum.map(&Map.get(&1, field)) |> Enum.sum()

  # The skipped time that can be believed; nil when no play is recent enough to believe.
  defp skipped(episodes, :believed) do
    case Enum.filter(episodes, &(&1.skipped != nil and &1.believed?)) do
      [] -> nil
      list -> list |> Enum.map(& &1.skipped) |> Enum.sum()
    end
  end

  # Laev's own sessions for this title, oldest first.
  defp sessions(base) do
    Laev.Stints.sessions()
    |> Enum.filter(&(&1.item == base))
    |> Enum.map(
      &%{started_at: &1.started_at, ended_at: &1.ended_at, seconds: &1.seconds, keys: &1.keys}
    )
  end

  defp started_watching([first | _], _finishes), do: %{at: first.started_at, how: :session}
  defp started_watching([], []), do: nil
  defp started_watching([], finishes), do: %{at: Enum.min(finishes), how: :finish}

  defp last_watched([], []), do: nil
  defp last_watched([], finishes), do: %{at: Enum.max(finishes), how: :finish}
  defp last_watched(sessions, _finishes), do: %{at: List.last(sessions).ended_at, how: :session}

  # When it was marked complete: the whole-title mark if there is one, else the last episode
  # marked or finished. `how` says which, and `state` whether that was a hand mark or a finish.
  defp marked(episodes, base) do
    done = Enum.filter(episodes, &(&1.state in [:marked, :finished] and &1.changed_at))

    case Enum.find(done, &(&1.name == base)) || Enum.max_by(done, & &1.changed_at, fn -> nil end) do
      nil ->
        nil

      e ->
        %{at: e.changed_at, how: if(e.name == base, do: :title, else: :episode), state: e.state}
    end
  end

  # ── reading ────────────────────────────────────────────────────────

  @doc "What the reader holds about one series, for the same popup."
  def reading(uuid, source, slug) do
    row =
      SavedManga
      |> where([s], s.user_id == ^uuid and s.source == ^source and s.slug == ^slug)
      |> Repo.one()

    if row do
      events =
        from(e in LibraryEvent,
          where: e.user_id == ^uuid and e.source == ^source and e.slug == ^slug,
          order_by: [asc: e.happened_at]
        )
        |> Repo.all()
        |> Enum.group_by(& &1.event, &DateTime.to_unix(&1.happened_at))

      {first_day, last_day, days} =
        from(a in ReadingActivity,
          where: a.user_id == ^uuid and a.source == ^source and a.slug == ^slug,
          select: {min(a.date), max(a.date), count(a.date, :distinct)}
        )
        |> Repo.one()

      sessions =
        from(s in Stint.Record,
          where: s.owner_id == ^uuid and s.item == ^"manga:#{source}/#{slug}",
          order_by: [desc: s.started_at]
        )
        |> Repo.all()
        |> Enum.map(
          &%{
            started_at: DateTime.to_unix(&1.started_at),
            ended_at: DateTime.to_unix(&1.ended_at),
            seconds: &1.seconds,
            keys: [&1.meta["chapter"]]
          }
        )

      %{
        kind: :reading,
        on_site: row.reading_seconds_adjusted || row.reading_seconds || 0,
        off_site: row.reading_seconds_offsite || 0,
        approximate?: row.reading_seconds_offsite_approximate == true,
        last_chapter: row.last_chapter,
        total_chapters: row.total_chapters,
        completed?: row.completed == true,
        started: events["started"] |> List.wrap() |> List.first(),
        completed_at: events["completed"] |> List.wrap() |> List.last(),
        caught_up_at: events["caught_up"] |> List.wrap() |> List.first(),
        first_day: first_day,
        last_day: last_day,
        days_read: days || 0,
        sessions: Enum.take(sessions, @sessions_shown),
        session_count: length(sessions),
        longest: sessions |> Enum.map(& &1.seconds) |> Enum.max(fn -> 0 end)
      }
    end
  end

  @doc "The popup's key for an entry: `\"tv:110316\"` for watching, `\"manga:mangafreak/slug\"` for reading."
  def encode(%{kind: :manga, key: {source, slug}}), do: "manga:#{source}/#{slug}"
  def encode(%{key: {type, id}}), do: "#{type}:#{id}"

  @doc "The other way round: `{:watching, {type, id}}`, `{:reading, source, slug}` or nil."
  def decode("manga:" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [source, slug] -> {:reading, source, slug}
      _ -> nil
    end
  end

  def decode(key) when is_binary(key) do
    with [type, id] <- String.split(key, ":", parts: 2),
         true <- type in ["movie", "tv", "mal"],
         {n, ""} <- Integer.parse(id) do
      {:watching, {type, n}}
    else
      _ -> nil
    end
  end

  def decode(_key), do: nil
end
