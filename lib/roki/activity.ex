defmodule Roki.Activity do
  @moduledoc """
  Recent activity: who finished what. Every episode or film finished in the player (or marked
  done when leaving an external player) is one row. The Featured page shows them grouped — a run
  of one person's episodes of one show, close together in time, is a *binge* ("alex binged 25
  episodes of Lupin"), newest first.

  Only people signed in to the site see it, and every account is in it: the site is a handful of
  friends, and the strip is what makes it feel shared.
  """

  alias Roki.Repo

  # A pause longer than this between two episodes of a show ends the run.
  @gap_s 6 * 3600
  # The same finish reported twice (player and "next") within this is one.
  @dup_s 600
  # How far back the strip looks.
  @window_days 30

  @topic "activity"

  def topic, do: @topic

  @doc """
  Remember that an episode or film was started (`"started"`) or finished (`"finished"`), from a
  play context, and tell the open pages. Opening a title and closing it again is not activity:
  a start is recorded only when playing begins.
  """
  def record(uuid, ctx, kind \\ "finished")

  def record(uuid, %{type: type, tmdb_id: id, title: title} = ctx, kind)
      when is_binary(uuid) and type in ["movie", "tv"] and is_integer(id) and is_binary(title) and
             kind in ["started", "finished"] do
    Task.start(fn ->
      season = if type == "tv", do: ctx[:season]
      episode = if type == "tv", do: ctx[:tmdb_episode] || ctx[:episode]
      {:ok, uuid_bin} = Ecto.UUID.dump(uuid)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      dup? =
        Repo.query!(
          """
          select 1 from roki_activity
           where user_uuid = $1 and type = $2 and tmdb_id = $3
             and season is not distinct from $4 and episode is not distinct from $5
             and kind = $7 and at > $6 limit 1
          """,
          [uuid_bin, type, id, season, episode, DateTime.add(now, -@dup_s), kind]
        ).num_rows > 0

      unless dup? do
        Repo.query!(
          """
          insert into roki_activity (user_uuid, type, tmdb_id, season, episode, title, poster, at, kind)
          values ($1, $2, $3, $4, $5, $6, $7, $8, $9)
          """,
          [uuid_bin, type, id, season, episode, title, poster_url(ctx[:poster_path]), now, kind]
        )

        Phoenix.PubSub.broadcast(Roki.PubSub, @topic, :activity)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  def record(_uuid, _ctx, _kind), do: :ok

  defp poster_url(nil), do: nil
  defp poster_url(path), do: Laev.Tmdb.poster_url(path, "w185")

  @doc """
  The newest `limit` runs: `[%{username, type, tmdb_id, title, poster, count, season, episode,
  at, binge?}]`, newest first.
  """
  def recent(limit \\ 14) do
    since = DateTime.utc_now() |> DateTime.add(-@window_days * 86_400)

    rows =
      Repo.query!(
        """
        select a.user_uuid::text, coalesce(nullif(u.username, ''), 'someone'), a.type, a.tmdb_id,
               a.season, a.episode, a.title, a.poster, a.at, a.kind
          from roki_activity a
          left join phoenix_kit_users u on u.uuid = a.user_uuid
         where a.at > $1
         order by a.at desc
         limit 1500
        """,
        [since]
      ).rows

    rows
    |> Enum.map(fn [user, name, type, id, season, episode, title, poster, at, kind] ->
      %{
        user: user,
        username: name,
        type: type,
        tmdb_id: id,
        season: season,
        episode: episode,
        title: title,
        poster: poster,
        at: to_utc(at),
        kind: kind
      }
    end)
    |> group()
    |> Enum.take(limit)
  end

  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp to_utc(%DateTime{} = at), do: at

  @doc """
  Turn single finishes (newest first) into runs: one person, one title, no gap over six hours.
  Pure, so it can be tested without a database.
  """
  def group(events) do
    events
    |> Enum.sort_by(& &1.at, {:asc, DateTime})
    |> Enum.group_by(&{&1.user, &1.type, &1.tmdb_id})
    |> Enum.flat_map(fn {_key, evs} -> runs(evs) end)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  defp runs(evs) do
    evs
    |> Enum.chunk_while(
      [],
      fn e, acc ->
        case acc do
          [] ->
            {:cont, [e]}

          [last | _] ->
            if DateTime.diff(e.at, last.at) > @gap_s,
              do: {:cont, Enum.reverse(acc), [e]},
              else: {:cont, [e | acc]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(&run/1)
  end

  # One run. Finished episodes are what it is about (and what a binge counts); a run with none —
  # only starts — is a start, of the last thing begun.
  defp run(evs) do
    finished = Enum.filter(evs, &(&1.kind == "finished"))
    {kind, shown} = if finished == [], do: {"started", evs}, else: {"finished", finished}
    last = List.last(shown)
    count = shown |> Enum.uniq_by(&{&1.season, &1.episode}) |> length()

    %{
      username: last.username,
      type: last.type,
      tmdb_id: last.tmdb_id,
      title: last.title,
      poster: Enum.find_value(Enum.reverse(evs), & &1.poster),
      count: if(kind == "started", do: 1, else: count),
      season: last.season,
      episode: last.episode,
      at: last.at,
      kind: kind,
      binge?: kind == "finished" and last.type == "tv" and count >= 3
    }
  end

  @doc "The sentence for a run, without the name: \"binged 25 episodes of\", \"started S2E4 of\"…"
  def verb(%{type: "movie", kind: "started"}), do: "started"
  def verb(%{type: "movie"}), do: "finished"
  def verb(%{binge?: true, count: n}), do: "binged #{n} episodes of"
  def verb(%{kind: "finished", count: 2}), do: "finished 2 episodes of"

  def verb(%{kind: kind, season: s, episode: e}) when is_integer(s) and is_integer(e),
    do: "#{kind} S#{s}E#{e} of"

  def verb(%{kind: kind}), do: kind
end
