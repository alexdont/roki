defmodule Roki.Activity do
  @moduledoc """
  Recent activity: who did what. A row is one of five kinds:

    * `finished` — an episode or film finished in the player (or marked done when leaving an
      external player);
    * `started` — watched ten minutes in;
    * `backdated` — marked watched and then put on an earlier day (`watched_on`). It is *not* a
      finish: nobody just watched it, they added it to their history. Backdating a title whose
      finish was just recorded turns that finish into this (`backdated/3`);
    * `saved` — put on the Saved list;
    * `rated` — given a rating (`score`).

  The Featured page shows them grouped, newest first — a run of one person's episodes of one
  show, close together in time, is a *binge* ("alex binged 25 episodes of Lupin"), and several
  films finished, saved or backdated by one person within an hour are one batch ("alex added 3
  films to their history"). It can be narrowed to one kind and to whose (everyone, friends, me).

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

  @kinds ["finished", "started", "saved", "rated", "backdated"]
  # Several of these by one person this close together are one batch.
  @batch_gap_s 3600

  @doc "The kinds of entry, in the order the filter lists them."
  def kinds, do: @kinds

  # Accounts that are for testing the site: what they do is not activity, so it is neither kept
  # nor shown.
  @silent ["test"]

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

  @doc """
  A start with how far in it is (`seconds`): the first time it crosses ten minutes it is added, and
  after that the same entry just follows the playhead (and rises to the top again). The open pages
  hear about it when it is new and then once a minute of progress.
  """
  def started(uuid, %{} = what, seconds)
      when is_integer(seconds) and seconds >= @started_after_s do
    Task.start(fn ->
      {:ok, uuid_bin} = Ecto.UUID.dump(uuid)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      key = [uuid_bin, what.type, what.tmdb_id, what.season, what.episode]

      %{rows: rows} =
        Repo.query!(
          """
          select id, seconds from roki_activity
           where user_uuid = $1 and type = $2 and tmdb_id = $3
             and season is not distinct from $4 and episode is not distinct from $5
             and kind = 'started' and at > $6
           order by id desc limit 1
          """,
          key ++ [DateTime.add(now, -12 * 3600)]
        )

      case rows do
        [] ->
          insert(uuid, Map.put(what, :seconds, seconds), "started")

        [[id, old]] ->
          Repo.query!("update roki_activity set seconds = $1, at = $2 where id = $3", [
            seconds,
            now,
            id
          ])

          if div(old || 0, 60) != div(seconds, 60),
            do: Phoenix.PubSub.broadcast(Roki.PubSub, @topic, :activity)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  def started(_uuid, _what, _seconds), do: :ok

  @doc """
  Insert one entry (`%{type, tmdb_id, title, poster, season, episode, watched_on, score}`) of one of
  the `kinds/0`, behind the caller, unless it is a repeat.
  """
  def insert(uuid, %{} = what, kind) when kind in @kinds do
    Task.start(fn -> insert_now(uuid, what, kind) end)
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  def insert_now(uuid, %{} = what, kind) when kind in @kinds do
    what = Map.merge(%{season: nil, episode: nil, poster: nil, watched_on: nil, score: nil}, what)

    try do
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

      silent? =
        Repo.query!("select 1 from phoenix_kit_users where uuid = $1 and username = any($2)", [
          uuid_bin,
          @silent
        ]).num_rows > 0

      unless dup? or silent? do
        Repo.query!(
          """
          insert into roki_activity (user_uuid, type, tmdb_id, season, episode, title, poster, at, kind, seconds, watched_on, score)
          values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
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
            kind,
            Map.get(what, :seconds),
            what.watched_on,
            what.score
          ]
        )

        Phoenix.PubSub.broadcast(Roki.PubSub, @topic, :activity)

        # A film finished is something friends who asked to hear about it are told (a series'
        # episodes are not: ten in a row would be ten notices).
        if kind == "finished" and what.type == "movie",
          do: Roki.Social.friend_activity(uuid, :finished, what.type, what.tmdb_id, what.title)
      end
    rescue
      _ -> :ok
    end

    :ok
  end

  @doc """
  Take back what an undone action put in the feed: a film or episode unmarked loses its `finished`
  and `backdated` entries, a title taken off the Saved list its `saved` one, a rating taken back its
  `rated` ones. `season`/`episode`
  narrow it to one episode; with both `nil` for a series, every episode of it goes. Open pages are
  told when something went.
  """
  def retract(uuid, type, tmdb_id, kinds, season \\ nil, episode \\ nil)
      when is_binary(uuid) and type in ["movie", "tv"] and is_integer(tmdb_id) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{num_rows: n} =
      Repo.query!(
        """
        delete from roki_activity
         where user_uuid = $1 and type = $2 and tmdb_id = $3 and kind = any($4)
           and ($5::int is null or season = $5)
           and ($6::int is null or episode = $6)
        """,
        [bin, type, tmdb_id, kinds, season, episode]
      )

    if n > 0, do: Phoenix.PubSub.broadcast(Roki.PubSub, @topic, :activity)
    n
  rescue
    _ -> 0
  end

  @doc """
  Take back the `rated` entries of a title: of the show as a whole (`season` nil) or of one
  season — the two are separate ratings and one never removes the other.
  """
  def retract_rated(uuid, type, tmdb_id, season \\ nil)
      when is_binary(uuid) and type in ["movie", "tv"] and is_integer(tmdb_id) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{num_rows: n} =
      Repo.query!(
        """
        delete from roki_activity
         where user_uuid = $1 and type = $2 and tmdb_id = $3 and kind = 'rated'
           and season is not distinct from $4
        """,
        [bin, type, tmdb_id, season]
      )

    if n > 0, do: Phoenix.PubSub.broadcast(Roki.PubSub, @topic, :activity)
    n
  rescue
    _ -> 0
  end

  @doc "Is this account one whose doings are not shown to anyone (the test account)?"
  def silent?(uuid) when is_binary(uuid) do
    Repo.query!("select 1 from phoenix_kit_users where uuid = $1 and username = any($2)", [
      Ecto.UUID.dump!(uuid),
      @silent
    ]).num_rows > 0
  end

  @doc "A title was put on the Saved list."
  def saved(uuid, %{type: type, id: id, title: title} = t)
      when type in ["movie", "tv"] and is_integer(id),
      do:
        insert(
          uuid,
          %{type: type, tmdb_id: id, title: title, poster: poster_url(t[:poster_path])},
          "saved"
        )

  def saved(_uuid, _title), do: :ok

  @doc "A title was rated (`score`, as given)."
  def rated(uuid, %{type: type, id: id, title: title} = t, score)
      when type in ["movie", "tv"] and is_integer(id) and is_number(score),
      do: rate_entry(uuid, type, id, title, t, score)

  def rated(_uuid, _title, _score), do: :ok

  # Rating it again replaces the entry rather than adding a second one: the older ratings of the
  # title go, then the new one is written, in that order, behind the caller.
  defp rate_entry(uuid, type, id, title, t, score) do
    Task.start(fn -> rated_now(uuid, %{t | type: type, id: id, title: title}, score) end)
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  def rated_now(uuid, %{type: type, id: id, title: title} = t, score) do
    retract_rated(uuid, type, id, t[:season])

    insert_now(
      uuid,
      %{
        type: type,
        tmdb_id: id,
        season: t[:season],
        title: title,
        poster: poster_url(t[:poster_path]),
        score: score * 1.0
      },
      "rated"
    )
  end

  @doc """
  Things the person put on an earlier day (`date`): `items` are `%{type, tmdb_id, title}`, the
  film or show as TMDB knows it. A finish recorded for one in the last `@window_days` days — the
  marking that came just before — *becomes* the backdating, since nobody finished it just now; a
  title with no such finish gets an entry of its own. Not recorded at all for the test account.
  Returns how many entries were turned or added.
  """
  def backdated(uuid, items, %Date{} = date) when is_binary(uuid) and is_list(items) do
    if silent?(uuid) do
      0
    else
      {:ok, bin} = Ecto.UUID.dump(uuid)

      since =
        DateTime.utc_now()
        |> DateTime.add(-@window_days * 86_400)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      counted =
        for %{type: type, tmdb_id: id, title: title} = item <- items,
            type in ["movie", "tv"],
            is_integer(id) do
          %{num_rows: turned} =
            Repo.query!(
              """
              update roki_activity set kind = 'backdated', watched_on = $4
               where user_uuid = $1 and type = $2 and tmdb_id = $3 and kind = 'finished' and at > $5
              """,
              [bin, type, id, date, since]
            )

          if turned == 0 do
            Repo.query!(
              """
              insert into roki_activity (user_uuid, type, tmdb_id, title, poster, at, kind, watched_on)
              values ($1, $2, $3, $4, $5, $6, 'backdated', $7)
              """,
              [bin, type, id, title, item[:poster], now, date]
            )
          end

          1
        end

      if counted != [], do: Phoenix.PubSub.broadcast(Roki.PubSub, @topic, :activity)
      length(counted)
    end
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

      started = for {k, d, _o} <- changed, secs(d) >= @started_after_s, do: {k, secs(d)}

      for key <- Enum.take(done ++ seen, 10),
          what = describe(uuid, key, resume),
          not recent_title?(uuid, what.type, what.tmdb_id, 1800) do
        insert(uuid, what, "finished")
      end

      for {key, seconds} <- Enum.take(started, 10),
          what = describe(uuid, key, resume) do
        started(uuid, what, seconds)
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

  @doc "A play context as what the activity functions take."
  def describe_ctx(%{type: type, tmdb_id: id, title: title} = ctx) do
    %{
      type: type,
      tmdb_id: id,
      title: title,
      poster: poster_url(ctx[:poster_path]),
      season: if(type == "tv", do: ctx[:season]),
      episode: if(type == "tv", do: ctx[:tmdb_episode] || ctx[:episode])
    }
  end

  defp poster_url(nil), do: nil
  defp poster_url(path), do: Laev.Tmdb.poster_url(path, "w185")

  @doc """
  The newest `limit` entries, grouped (see `group/1`): `[%{user, username, type, tmdb_id, title,
  poster, count, season, episode, at, kind, seconds, watched_on, score, binge?, batch?, items}]`,
  newest first. Options: `:kinds` (a list of `kinds/0`; default all) and `:users` (a list of user
  uuids, to look at only theirs; default everyone).
  """
  def recent(limit \\ 14, opts \\ []) do
    since = DateTime.utc_now() |> DateTime.add(-@window_days * 86_400)
    kinds = (opts[:kinds] || @kinds) |> Enum.filter(&(&1 in @kinds))
    users = if opts[:users], do: Enum.map(opts[:users], &Ecto.UUID.dump!/1)

    rows =
      Repo.query!(
        """
        select a.user_uuid::text, coalesce(nullif(u.username, ''), 'someone'), a.type, a.tmdb_id,
               a.season, a.episode, a.title, a.poster, a.at, a.kind, a.seconds, a.watched_on, a.score
          from roki_activity a
          join phoenix_kit_users u on u.uuid = a.user_uuid
         where a.at > $1
           and coalesce(u.username, '') <> all($2)
           and a.kind = any($3)
           and ($4::uuid[] is null or a.user_uuid = any($4::uuid[]))
         order by a.at desc
         limit 1500
        """,
        [since, @silent, kinds, users]
      ).rows

    rows
    |> Enum.map(fn [
                     user,
                     name,
                     type,
                     id,
                     season,
                     episode,
                     title,
                     poster,
                     at,
                     kind,
                     seconds,
                     watched_on,
                     score
                   ] ->
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
        kind: kind,
        seconds: seconds,
        watched_on: watched_on,
        score: score
      }
    end)
    |> group()
    |> Enum.take(limit)
  end

  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp to_utc(%DateTime{} = at), do: at

  @doc """
  Turn single entries into what the feed shows, newest first. Pure, so it can be tested without a
  database.

  Finishes and starts of one show by one person with no gap over six hours are a *run* (a binge
  when it is three episodes or more). Saves, ratings and backdatings stand alone. Then several
  films finished — or titles saved, or put on an earlier day — by one person within an hour
  become one *batch*: `batch?: true`, `items` the entries, `count` how many.
  """
  def group(events) do
    {played, other} = Enum.split_with(events, &(&1.kind in ["started", "finished"]))

    runs =
      played
      |> Enum.sort_by(& &1.at, {:asc, DateTime})
      |> Enum.group_by(&{&1.user, &1.type, &1.tmdb_id})
      |> Enum.flat_map(fn {_key, evs} -> runs(evs) end)

    {runs, singles} = fold_ratings(runs, Enum.map(other, &single/1))

    (runs ++ singles)
    |> batch()
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  # A rating given in the same sitting as the watching belongs to it: "watched 3 episodes and rated
  # 6", not two lines. A rating joins the finished run of that title by that person nearest to it
  # in time, within the run gap; the run then carries `score` and the rating is not shown alone.
  defp fold_ratings(runs, singles) do
    Enum.reduce(singles, {runs, []}, fn single, {runs, kept} ->
      with "rated" <- single.kind,
           {run, diff} when diff <= @gap_s <- nearest_run(runs, single) do
        merged = %{run | score: single.score, at: Enum.max([run.at, single.at], DateTime)}
        {Enum.map(runs, &if(&1 == run, do: merged, else: &1)), kept}
      else
        _ -> {runs, [single | kept]}
      end
    end)
    |> then(fn {runs, kept} -> {runs, Enum.reverse(kept)} end)
  end

  defp nearest_run(runs, single) do
    runs
    |> Enum.filter(
      &(&1.kind == "finished" and is_nil(&1.score) and &1.user == single.user and
          &1.type == single.type and &1.tmdb_id == single.tmdb_id and
          (is_nil(single.season) or single.season == &1.season))
    )
    |> Enum.map(&{&1, abs(DateTime.diff(&1.at, single.at))})
    |> Enum.min_by(&elem(&1, 1), fn -> nil end)
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
      user: last.user,
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
      seconds: if(kind == "started", do: last[:seconds]),
      watched_on: nil,
      score: nil,
      binge?: kind == "finished" and last.type == "tv" and count >= 3,
      batch?: false,
      items: []
    }
  end

  # A save, a rating or a backdating: one entry, on its own.
  defp single(e) do
    %{
      user: e.user,
      username: e.username,
      type: e.type,
      tmdb_id: e.tmdb_id,
      title: e.title,
      poster: e.poster,
      count: 1,
      season: e.season,
      episode: e.episode,
      at: e.at,
      kind: e.kind,
      seconds: nil,
      watched_on: e[:watched_on],
      score: e[:score],
      binge?: false,
      batch?: false,
      items: []
    }
  end

  # Films finished (and titles saved or backdated) by one person within an hour of each other.
  defp batch(runs) do
    {candidates, rest} = Enum.split_with(runs, &batchable?/1)

    merged =
      candidates
      |> Enum.group_by(&{&1.user, &1.kind})
      |> Enum.flat_map(fn {_key, items} ->
        items
        |> Enum.sort_by(& &1.at, {:asc, DateTime})
        |> Enum.chunk_while(
          [],
          fn item, acc ->
            case acc do
              [] ->
                {:cont, [item]}

              [last | _] ->
                if DateTime.diff(item.at, last.at) > @batch_gap_s,
                  do: {:cont, Enum.reverse(acc), [item]},
                  else: {:cont, [item | acc]}
            end
          end,
          fn
            [] -> {:cont, []}
            acc -> {:cont, Enum.reverse(acc), []}
          end
        )
        |> Enum.map(&one_or_batch/1)
      end)

    rest ++ merged
  end

  defp batchable?(%{kind: kind}) when kind in ["saved", "backdated"], do: true
  defp batchable?(%{kind: "finished", type: "movie"}), do: true
  defp batchable?(_), do: false

  defp one_or_batch([only]), do: only

  defp one_or_batch(items) do
    newest_first = Enum.reverse(items)
    first = hd(newest_first)

    %{
      first
      | batch?: true,
        count: length(items),
        items: newest_first,
        at: first.at,
        watched_on: nil
    }
  end

  @doc "How a feed entry reads: `%{verb, subject, after, detail, icon, tone}`; `subject` is the title when it is one."
  def describe(%{batch?: true, kind: kind, count: n, items: items}) do
    names =
      items
      |> Enum.map(& &1.title)
      |> Enum.take(3)
      |> Enum.join(", ")
      |> then(&if(n > 3, do: &1 <> "…", else: &1))

    what = if Enum.all?(items, &(&1.type == "movie")), do: "#{n} films", else: "#{n} titles"

    {verb, after_} =
      case kind do
        "finished" -> {"finished #{what}", nil}
        "saved" -> {"saved #{what}", "for later"}
        "backdated" -> {"added #{what}", "to their history"}
      end

    # When it was really watched comes first: it is what a backdating is about, and the names may be long.
    detail =
      [if(kind == "backdated", do: dates_text(items)), names]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    Map.merge(%{verb: verb, subject: nil, after: after_, detail: detail}, look(kind))
  end

  def describe(%{kind: "backdated"} = e),
    do:
      Map.merge(
        %{verb: "added", subject: e.title, after: "to their history", detail: dates_text([e])},
        look("backdated")
      )

  def describe(%{kind: "saved"} = e),
    do:
      Map.merge(
        %{verb: "saved", subject: e.title, after: "for later", detail: nil},
        look("saved")
      )

  def describe(%{kind: "rated"} = e),
    do:
      Map.merge(
        %{
          verb: "rated",
          subject: e.title,
          after: if(is_integer(e.season), do: "season #{e.season}"),
          detail: score_text(e.score)
        },
        look("rated")
      )

  def describe(%{kind: kind} = e) do
    {before, subject} = split_verb(e)

    Map.merge(
      %{
        verb: before,
        subject: subject,
        after: nil,
        detail:
          [
            if(watched_text(e), do: watched_text(e) <> " watched"),
            if(e[:score], do: "rated " <> score_text(e.score))
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" · ")
          |> then(&if(&1 == "", do: nil, else: &1))
      },
      look(kind)
    )
  end

  # What a run reads as, with the title taken out of the sentence `verb/1` makes.
  defp split_verb(e), do: {verb(e), e.title}

  defp look("finished"), do: %{icon: "hero-eye", tone: "success"}
  defp look("started"), do: %{icon: "hero-play-circle", tone: "info"}
  defp look("saved"), do: %{icon: "hero-bookmark", tone: "primary"}
  defp look("rated"), do: %{icon: "hero-star", tone: "warning"}
  defp look("backdated"), do: %{icon: "hero-clock", tone: "secondary"}

  defp score_text(nil), do: nil
  defp score_text(score), do: "★ " <> Roki.Profile.score_text(score)

  # "watched Oct 3", "watched Oct 3 – Oct 9" for entries put on different days.
  defp dates_text(items) do
    dates = items |> Enum.map(& &1.watched_on) |> Enum.reject(&is_nil/1) |> Enum.sort(Date)

    case dates do
      [] ->
        nil

      [only] ->
        "watched " <> day(only)

      many ->
        if List.first(many) == List.last(many),
          do: "watched " <> day(hd(many)),
          else: "watched #{day(List.first(many))} – #{day(List.last(many))}"
    end
  end

  defp day(%Date{} = date) do
    if date.year == Date.utc_today().year,
      do: Calendar.strftime(date, "%b %-d"),
      else: Calendar.strftime(date, "%b %-d, %Y")
  end

  @doc "\"23:32\" or \"1:05:09\": how far in a started entry is, or nil."
  def watched_text(%{kind: "started", seconds: s}) when is_integer(s) and s > 0 do
    {h, rest} = {div(s, 3600), rem(s, 3600)}
    m = div(rest, 60)
    sec = rem(rest, 60)

    if h > 0,
      do: "#{h}:#{pad(m)}:#{pad(sec)}",
      else: "#{m}:#{pad(sec)}"
  end

  def watched_text(_), do: nil

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "The sentence for a run, without the name: \"binged 25 episodes of\", \"started S2E4 of\"…"
  def verb(%{type: "movie", kind: "started"}), do: "started"
  def verb(%{type: "movie"}), do: "finished"
  def verb(%{binge?: true, count: n}), do: "binged #{n} episodes of"
  def verb(%{kind: "finished", count: 2}), do: "finished 2 episodes of"

  def verb(%{kind: kind, season: s, episode: e}) when is_integer(s) and is_integer(e),
    do: "#{kind} S#{s}E#{e} of"

  def verb(%{kind: kind}), do: kind
end
