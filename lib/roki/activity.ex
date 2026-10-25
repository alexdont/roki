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

  # Watching this long (seconds into it) is what makes something "started": opening a title and
  # closing it again is not activity.
  @started_after_s 600

  def started_after_s, do: @started_after_s

  @doc """
  Remember that an episode or film was started (`"started"`) or finished (`"finished"`), from a
  play context, and tell the open pages. Starts are recorded once `@started_after_s` seconds in
  (see `Roki.Watch.record_progress/5`); a finish is an episode or film played to the end, or one
  marked watched on its own (not a whole season at once).
  """
  def record(uuid, ctx, kind \\ "finished")

  def record(uuid, %{type: type, tmdb_id: id, title: title} = ctx, kind)
      when is_binary(uuid) and type in ["movie", "tv"] and is_integer(id) and is_binary(title) and
             kind in ["started", "finished"] do
    insert(
      uuid,
      %{
        type: type,
        tmdb_id: id,
        title: title,
        poster: poster_url(ctx[:poster_path]),
        season: if(type == "tv", do: ctx[:season]),
        episode: if(type == "tv", do: ctx[:tmdb_episode] || ctx[:episode])
      },
      kind
    )
  end

  def record(_uuid, _ctx, _kind), do: :ok

  @doc "Insert one entry (`%{type, tmdb_id, title, poster, season, episode}`) unless it is a repeat."
  def insert(uuid, %{} = what, kind) when kind in ["started", "finished"] do
    Task.start(fn ->
      {:ok, uuid_bin} = Ecto.UUID.dump(uuid)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      # A start is one per episode per half day however long it is watched; a finish twice in
      # ten minutes is one.
      window = if kind == "started", do: 12 * 3600, else: @dup_s

      dup? =
        Repo.query!(
          """
          select 1 from roki_activity
           where user_uuid = $1 and type = $2 and tmdb_id = $3
             and season is not distinct from $4 and episode is not distinct from $5
             and kind = $7 and at > $6 limit 1
          """,
          [
            uuid_bin,
            what.type,
            what.tmdb_id,
            what.season,
            what.episode,
            DateTime.add(now, -window),
            kind
          ]
        ).num_rows > 0

      unless dup? do
        Repo.query!(
          """
          insert into roki_activity (user_uuid, type, tmdb_id, season, episode, title, poster, at, kind)
          values ($1, $2, $3, $4, $5, $6, $7, $8, $9)
          """,
          [
            uuid_bin,
            what.type,
            what.tmdb_id,
            what.season,
            what.episode,
            what.title,
            what.poster,
            now,
            kind
          ]
        )

        Phoenix.PubSub.broadcast(Roki.PubSub, @topic, :activity)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  # ── from the terminal app ──────────────────────────────────────────

  @doc """
  The terminal app syncs through this site, so what it does shows up here too: given a person's
  synced document before and after a merge, anything newly finished (`done`), newly marked on its
  own (`seen`, a few at a time — an import is not activity) or watched past `@started_after_s` seconds
  becomes an entry. Titles are named from the document's own `resume` records, so a title the
  terminal app never played is skipped. Whatever the site recorded itself a moment ago for the same
  title is not repeated.
  """
  def from_sync(token, before, after_) when is_binary(token) do
    with uuid when is_binary(uuid) <- user_for(token) do
      old = Map.get(before, "positions") || %{}
      new = Map.get(after_, "positions") || %{}
      resume = Map.get(after_, "resume") || %{}
      cutoff = System.os_time(:second) - 2 * 3600

      changed =
        for {key, %{"data" => data, "deleted" => false} = rec} <- new,
            rec != Map.get(old, key),
            (rec["updated_at"] || 0) >= cutoff,
            do: {key, data, Map.get(old, key)}

      done =
        for {k, "done", o} <- changed,
            not match?(%{"data" => "done", "deleted" => false}, o),
            do: k

      seen =
        for {k, "seen", o} <- changed,
            not match?(%{"data" => "seen", "deleted" => false}, o),
            do: k

      seen = if length(seen) <= 3, do: seen, else: []

      started =
        for {k, d, o} <- changed,
            secs(d) >= @started_after_s,
            secs(old_data(o)) < @started_after_s,
            do: k

      for {kind, keys} <- [{"finished", done ++ seen}, {"started", started}],
          key <- Enum.take(keys, 10),
          what = describe(uuid, key, resume),
          not recent_title?(uuid, what.type, what.tmdb_id, 1800) do
        insert(uuid, what, kind)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  def from_sync(_token, _before, _after), do: :ok

  defp secs(data) when is_binary(data) do
    case Integer.parse(data) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp secs(_), do: 0

  defp old_data(%{"data" => d, "deleted" => false}), do: d
  defp old_data(_), do: nil

  # A position key (`movie-ID`, `tv-ID-sSeE`, `tv-ID-eE`, `mal-ID-eE`) as something to show.
  defp describe(uuid, key, resume) do
    case Regex.run(~r/^(movie|tv|mal)-(\d+)(?:-s(\d+))?(?:-?e(\d+))?$/, key) do
      [_, "movie", id] ->
        named(resume, "movie", String.to_integer(id), nil, nil)

      [_, "movie", id, _] ->
        named(resume, "movie", String.to_integer(id), nil, nil)

      [_, "tv", id, season, ep] when ep != "" ->
        named(resume, "tv", String.to_integer(id), season_of(season), String.to_integer(ep))

      [_, "tv", id, "", ep] when ep != "" ->
        named(resume, "tv", String.to_integer(id), 1, String.to_integer(ep))

      [_, "mal", mal, _, ep] when ep != "" ->
        mal = String.to_integer(mal)
        local = String.to_integer(ep)

        case Roki.Laev.run(uuid, fn -> Laev.AnimeMap.tmdb(mal) end) do
          {"tv", tmdb, season} ->
            season = season || 1

            tmdb_ep =
              Roki.Laev.run(uuid, fn -> Laev.Anime.Parts.to_tmdb(tmdb, season, mal, local) end)

            named(resume, "tv", tmdb, season, tmdb_ep)

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp season_of(""), do: 1
  defp season_of(s), do: String.to_integer(s)

  defp named(resume, type, id, season, episode) do
    case get_in(resume, ["#{type}:#{id}", "data"]) do
      %{"title" => title} = r when is_binary(title) ->
        %{
          type: type,
          tmdb_id: id,
          title: title,
          poster: poster_url(r["poster_path"]),
          season: season,
          episode: episode
        }

      _ ->
        nil
    end
  end

  @doc "Has this person got an entry for this title in the last `seconds`?"
  def recent_title?(uuid, type, tmdb_id, seconds) do
    {:ok, uuid_bin} = Ecto.UUID.dump(uuid)

    Repo.query!(
      "select 1 from roki_activity where user_uuid = $1 and type = $2 and tmdb_id = $3 and at > $4 limit 1",
      [uuid_bin, type, tmdb_id, DateTime.add(DateTime.utc_now(), -seconds)]
    ).num_rows > 0
  end

  # Which account a laev key belongs to: the keys are in each account's own laev config.
  defp user_for(token) do
    {:ok, map} =
      Roki.TTLCache.fetch(:sync_tokens, 60, fn ->
        base = Roki.Laev.base_dir()

        tokens =
          for dir <- File.ls!(base),
              {:ok, _} <- [Ecto.UUID.cast(dir)],
              cfg = Laev.Config.read_dir(Path.join(base, dir)),
              t = cfg[:sync_token],
              is_binary(t),
              into: %{},
              do: {t, dir}

        {:ok, tokens}
      end)

    Map.get(map, token)
  end

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
