defmodule Roki.Profile do
  @moduledoc """
  A user's public page (`/:username`): a banner and a few words of their own, and what they
  have watched — newest first, or by their own ratings, so the ten-out-of-tens can be shown.

  Every profile is open — the site is a handful of people who know each other — so the privacy
  switches the table still has are not consulted. The history is laev's list of finished titles, read in the owner's
  scope and remembered for a few minutes; the ratings are copied into the site's own table from
  TMDB (the owner's TMDB account) and MyAnimeList (their list) now and then, and kept up to date
  by the ratings made here, so a visitor's view never needs the owner's keys.
  """

  alias Roki.{Repo, TTLCache}

  @bio_max 600
  @history_ttl_s 5 * 60
  @ratings_every_s 3600

  @defaults %{
    bio: "",
    banner: nil,
    public: false,
    show_history: true,
    show_ratings: true,
    ratings_synced_at: nil,
    ranked: []
  }

  # ── who ───────────────────────────────────────────────────────────

  @doc "The account behind a username, or nil."
  def user(username) when is_binary(username) and username != "",
    do: PhoenixKit.Users.Auth.get_user_by_username(username)

  def user(_), do: nil

  # ── the profile row ───────────────────────────────────────────────

  @doc "The profile of a user: the row, or the defaults (private, nothing written) for one who never set it up."
  def get(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    case Repo.query!(
           "select bio, banner, public, show_history, show_ratings, ratings_synced_at, ranked from roki_profiles where user_uuid = $1",
           [bin]
         ) do
      %{rows: [[bio, banner, _public, _history, _ratings, synced, ranked]]} ->
        %{
          user_uuid: uuid,
          bio: bio || "",
          banner: banner,
          public: true,
          show_history: true,
          show_ratings: true,
          ratings_synced_at: synced,
          ranked: ranked || []
        }

      _ ->
        @defaults
        |> Map.merge(%{public: true, show_history: true, show_ratings: true})
        |> Map.put(:user_uuid, uuid)
    end
  end

  @doc """
  Change what the owner wrote and chose: `bio` (text, at most #{@bio_max} characters), `public`,
  `show_history`, `show_ratings` (true/false or "true"/"false"). `{:ok, profile}` or
  `{:error, message}`.
  """
  def update(uuid, attrs) when is_binary(uuid) and is_map(attrs) do
    current = get(uuid)
    bio = attrs |> Map.get("bio", current.bio) |> to_string() |> String.trim()

    if String.length(bio) > @bio_max do
      {:error, "Keep the description under #{@bio_max} characters."}
    else
      flags =
        for key <- [:public, :show_history, :show_ratings], into: %{} do
          {key, bool(Map.get(attrs, Atom.to_string(key), current[key]))}
        end

      {:ok, bin} = Ecto.UUID.dump(uuid)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.query!(
        """
        insert into roki_profiles (user_uuid, bio, public, show_history, show_ratings, inserted_at, updated_at)
        values ($1, $2, $3, $4, $5, $6, $6)
        on conflict (user_uuid) do update
          set bio = excluded.bio, public = excluded.public, show_history = excluded.show_history,
              show_ratings = excluded.show_ratings, updated_at = excluded.updated_at
        """,
        [bin, bio, flags.public, flags.show_history, flags.show_ratings, now]
      )

      {:ok, get(uuid)}
    end
  end

  defp bool(true), do: true
  defp bool("true"), do: true
  defp bool("on"), do: true
  defp bool(_), do: false

  # ── the banner ────────────────────────────────────────────────────

  @doc "The address a profile's banner is served at (a file in the media library, `Roki.Media`), or nil without one."
  def banner_url(%{banner: uuid}) when is_binary(uuid) and uuid != "",
    do: if(Roki.Media.uuid?(uuid), do: Roki.Media.url(uuid))

  def banner_url(_profile), do: nil

  @doc """
  Keep an uploaded picture as the user's banner: made into a JPEG no wider than 1800 px (a
  phone's photo is far larger than any screen it is shown on) and put into the media library
  under the user's name, in the "Profile banners" folder. `{:ok, profile}` or `{:error, message}`.
  """
  def store_banner(uuid, path) when is_binary(uuid) and is_binary(path) do
    out = Path.join(System.tmp_dir!(), "roki-banner-#{System.unique_integer([:positive])}.jpg")

    args =
      ~w(-nostdin -loglevel error -y -i) ++
        [path, "-frames:v", "1", "-vf", "scale='min(1800,iw)':-2", "-q:v", "4", out]

    try do
      with {_, 0} <- System.cmd("ffmpeg", args, stderr_to_stdout: true),
           {:ok, file_uuid} <-
             Roki.Media.store(out,
               user: uuid,
               folder: "Profile banners",
               filename: "banner-#{System.os_time(:second)}.jpg"
             ) do
        set_banner(uuid, file_uuid)
        {:ok, get(uuid)}
      else
        {out_text, code} when is_integer(code) ->
          {:error,
           "That picture could not be read (#{String.slice(String.trim(out_text), 0, 80)})."}

        {:error, reason} ->
          {:error, "The picture could not be kept (#{inspect(reason) |> String.slice(0, 80)})."}
      end
    after
      File.rm(out)
    end
  end

  @doc "Take the banner off the profile (the file stays in the media library, the user's to keep or delete)."
  def clear_banner(uuid) when is_binary(uuid) do
    set_banner(uuid, nil)
    :ok
  end

  defp set_banner(uuid, name) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.query!(
      """
      insert into roki_profiles (user_uuid, banner, inserted_at, updated_at) values ($1, $2, $3, $3)
      on conflict (user_uuid) do update set banner = excluded.banner, updated_at = excluded.updated_at
      """,
      [bin, name, now]
    )

    :ok
  end

  # ── what they watched ─────────────────────────────────────────────

  @doc """
  Everything the user finished, newest first: `[%{type:, id:, mal_id:, season:, title:,
  poster:, anime:, at:, dated?:}]`, from the site's own table of finished titles, which is
  filled from laev's marks (`Roki.Laev.completed/1`) when it is five minutes old or more —
  a profile is looked at more often than it changes, and the table is there whether laev is
  reachable or not. Posters come from the site's copy of the titles (`Roki.Titles`).
  """
  def history(uuid) when is_binary(uuid) do
    sync_watched(uuid)
    Enum.filter(read_watched(uuid), &(&1.status == "finished"))
  end

  @doc """
  Everything watched, finished or not, in the same shape as `history/1` with `status`
  (`"finished"`, `"progress"`, `"up_to_date"`, `"on_hold"`) and `note` on each. The watched page
  reads this; the counts, the hours and the shelf pickers read `history/1`, which is only what
  was finished.
  """
  def history_all(uuid) when is_binary(uuid) do
    sync_watched(uuid)
    read_watched(uuid)
  end

  @doc """
  The numbers on a profile, counted from what is finished: `%{watched:, films:}` at once from
  the site's table; see `hours/1` for the rest.
  """
  def counts(uuid) when is_binary(uuid) do
    items = history(uuid)
    %{watched: length(items), films: Enum.count(items, &(&1.type == "movie"))}
  end

  @doc """
  `%{hours:, episodes:}` for a profile: laev's total time and episodes, with each finished
  film at least its whole runtime. Laev bills a title it played itself only the seconds it
  measured — a film played for four minutes and then marked finished is four minutes — which
  is right for its own statistics and wrong for a profile that says "3 films watched, 20
  minutes". `{:error, why}` when laev's stats cannot be had.
  """
  def hours(uuid) when is_binary(uuid) do
    with {:ok, %{totals: totals}} <- totals(uuid) do
      {:ok, %{hours: div(totals.seconds || 0, 3600), episodes: totals.episodes}}
    end
  end

  @doc """
  Laev's statistics summary with the profile's own reckoning laid over its totals: every
  finished film at least its whole runtime, and the film count taken from what is finished
  here. The home page and the profile both read this, so the two never show different numbers
  for the same person. `{:error, why}` when laev's stats cannot be had.
  """
  def totals(uuid) when is_binary(uuid) do
    with {:ok, measured} = ok <- measure_totals(uuid) do
      Roki.Laev.remember_totals(uuid, measured)
      ok
    end
  end

  @doc """
  The last totals this account had, if any are kept — `{:ok, totals}` or `:miss`. Read from
  memory (or a small file), never worked out, so a page can have them on its first frame.
  """
  def kept_totals(uuid) when is_binary(uuid) do
    case Roki.Laev.cached_totals(uuid) do
      {:ok, totals, _age} -> {:ok, totals}
      :miss -> :miss
    end
  end

  defp measure_totals(uuid) do
    with {:ok, %{totals: totals} = summary} <- Roki.Stats.summary(uuid) do
      billed = Map.get(summary, :films, %{})
      ids = for i <- history(uuid), i.type == "movie", do: i.id

      runtimes =
        if ids == [] do
          %{}
        else
          Repo.query!(
            "select id, (data->>'minutes')::int from roki_titles where type = 'movie' and id = any($1) and data is not null and jsonb_typeof(data) = 'object'",
            [ids]
          ).rows
          |> Map.new(fn [id, minutes] -> {id, minutes} end)
        end

      topped =
        Enum.reduce(ids, 0, fn id, sum ->
          case runtimes[id] do
            minutes when is_integer(minutes) ->
              sum + max(minutes * 60 - Map.get(billed, id, 0), 0)

            _ ->
              sum
          end
        end)

      {:ok,
       %{
         summary
         | totals: %{totals | seconds: (totals.seconds || 0) + topped, films: length(ids)}
       }}
    end
  end

  @doc """
  Say when things were watched: `keys` (`\"movie:603\"`, `\"tv:1396\"`, `\"mal:5114\"`, as the
  history lists them) are put on `date` — in the order given, the first the latest of the day, so
  a batch keeps its order — wherever they were in the history. Kept across every later sync, so
  a film found years afterwards and marked finished can go back where it belongs instead of
  topping the list. `{:ok, how_many}`.
  """
  def set_watched_at(uuid, keys, %Date{} = date) when is_binary(uuid) and is_list(keys) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    parsed = keys |> Enum.map(&parse_key/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    base = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")
    total = length(parsed)

    {:ok, {dated, dated_keys}} =
      Repo.transaction(fn ->
        for {{type, id}, i} <- Enum.with_index(parsed), reduce: {0, []} do
          {count, keys} ->
            at = DateTime.add(base, total - i, :second)

            %{num_rows: n} =
              Repo.query!(
                "update roki_watched set at = $4, dated = true where user_uuid = $1 and type = $2 and id = $3",
                [bin, type, id, at]
              )

            # Only what is on the list can be dated.
            if n > 0 do
              Repo.query!(
                """
                insert into roki_watch_dates (user_uuid, type, id, watched_at) values ($1, $2, $3, $4)
                on conflict (user_uuid, type, id) do update set watched_at = excluded.watched_at
                """,
                [bin, type, id, at]
              )

              {count + 1, [{type, id, at} | keys]}
            else
              {count, keys}
            end
        end
      end)

    # Laev is told too (0.1.48, `Laev.Position.set_watched_on/2`: a claimed date, kept apart from
    # what it measured), so the terminal app and laev's own stats put the title on that day, and
    # a later sync brings the same date back here rather than none.
    tell_laev_dates(uuid, dated_keys)

    # The activity feed: a finish recorded a moment ago for these was a marking, and is now a
    # backdating — it must not read as if they had just watched it.
    items =
      for {type, id} <- parsed,
          [tmdb_type, tmdb_id, title] <-
            Repo.query!(
              "select tmdb_type, tmdb_id, title from roki_watched where user_uuid = $1 and type = $2 and id = $3",
              [bin, type, id]
            ).rows,
          tmdb_type in ["movie", "tv"] and is_integer(tmdb_id) do
        %{
          type: tmdb_type,
          tmdb_id: tmdb_id,
          title: title || "Untitled",
          poster: (Roki.Titles.card(tmdb_type, tmdb_id) || %{})[:poster]
        }
      end

    Roki.Activity.backdated(uuid, items, date)

    {:ok, dated}
  end

  defp tell_laev_dates(uuid, keys) when keys != [] do
    if Roki.Laev.connected?(uuid) do
      Roki.Laev.run(uuid, fn ->
        for {type, id, at} <- keys do
          ctx = if type == "mal", do: %{mal_id: id}, else: %{type: type, tmdb_id: id}
          Laev.Position.set_watched_on(ctx, DateTime.to_unix(at))
        end
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp tell_laev_dates(_uuid, _keys), do: :ok

  @doc """
  Take titles off the watched list: the marks go (in laev, so the terminal app and the other
  devices agree), their dates and their rows with them. A rating stays a rating. `{:ok, how_many}`.
  """
  def remove_watched(uuid, keys) when is_binary(uuid) and is_list(keys) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    parsed = keys |> Enum.map(&parse_key/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    for {type, id} <- parsed do
      Roki.Watch.unmark(uuid, type, id)

      Repo.query!("delete from roki_watched where user_uuid = $1 and type = $2 and id = $3", [
        bin,
        type,
        id
      ])

      Repo.query!("delete from roki_watch_dates where user_uuid = $1 and type = $2 and id = $3", [
        bin,
        type,
        id
      ])
    end

    {:ok, length(parsed)}
  end

  @doc """
  Forget when the finished titles were last copied, and copy them again at once, behind the
  caller. Every change to what is watched ends here, so a title marked watched is on the list —
  dated that moment, see `date_new_marks/3` — before anyone opens a page, not when someone
  next does.
  """
  def forget_history(uuid) do
    TTLCache.delete({:watched_sync, uuid})
    Task.start(fn -> sync_watched(uuid) end)
    :ok
  end

  # laev's finished titles into the table, their cards into the title store; once per five
  # minutes, one at a time.
  defp sync_watched(uuid) do
    if Roki.Laev.connected?(uuid) and not TTLCache.cached?({:watched_sync, uuid}) do
      TTLCache.fetch({:watched_sync, uuid}, @history_ttl_s, fn ->
        finished =
          Roki.Laev.completed(uuid) |> Enum.map(&Map.merge(%{status: "finished", note: nil}, &1))

        # Started and not finished: the rest of what was watched. A title laev also calls
        # finished stays finished.
        unfinished =
          case Roki.Laev.unfinished(uuid) do
            list when is_list(list) -> list
            _ -> []
          end

        items = finished ++ unfinished

        Roki.Titles.remember(
          for i <- items,
              i.type != nil,
              do: %{type: i.type, id: i.id, title: i.title, poster: i.poster}
        )

        replace_watched(uuid, items)
        # What genres these are, read behind the page (once each, kept).
        Roki.Genres.fill_later(
          for(i <- items, i.type in ["movie", "tv"], is_integer(i.id), do: {i.type, i.id}),
          uuid
        )

        {:ok, :done}
      end)
    end

    :ok
  end

  @doc false
  def replace_watched(uuid, items) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    rows =
      items
      |> Enum.map(fn i ->
        {type, id} = if is_integer(i[:mal_id]), do: {"mal", i.mal_id}, else: {i.type, i.id}

        {type, id, i.type, i.id, i[:season], i[:title], i[:anime] == true,
         DateTime.from_unix!(max(i.at || 0, 0)), i[:dated?] == true, i[:status] || "finished",
         i[:note]}
      end)
      |> Enum.filter(fn {type, id, _, _, _, _, _, _, _, _, _} ->
        is_binary(type) and is_integer(id)
      end)
      |> Enum.uniq_by(fn {type, id, _, _, _, _, _, _, _, _, _} -> {type, id} end)

    Repo.transaction(fn ->
      before =
        Repo.query!("select type, id from roki_watched where user_uuid = $1", [bin]).rows
        |> MapSet.new(fn [t, i] -> {t, i} end)

      Repo.query!("delete from roki_watched where user_uuid = $1", [bin])

      rows
      |> Enum.chunk_every(300)
      |> Enum.each(fn chunk ->
        {values, params} =
          chunk
          |> Enum.with_index()
          |> Enum.map_reduce([], fn {{type, id, tt, tid, season, title, anime, at, dated, status,
                                      note}, i},
                                    acc ->
            n = i * 11

            {"($1, " <> Enum.map_join(2..12, ", ", &"$#{n + &1}") <> ")",
             acc ++ [type, id, tt, tid, season, title, anime, at, dated, status, note]}
          end)

        Repo.query!(
          "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, season, title, anime, at, dated, status, note) values " <>
            Enum.join(values, ", "),
          [bin | params]
        )
      end)

      date_new_marks(bin, rows, before)
      apply_dates(bin)
    end)

    :ok
  end

  # Laev keeps no date for a title marked watched without playing it, so such a title would sink
  # to the bottom of the history under "No date" — exactly where a film marked a minute ago must
  # not be. A title that shows up undated *now*, on a list that already had titles, was marked
  # since the last look, so it is dated now (and kept, like any date the owner sets). The first
  # copy of an account is left alone: its undated titles are old, not new.
  @marks_per_look 25

  defp date_new_marks(bin, rows, before) do
    if MapSet.size(before) > 0, do: date_marks(bin, rows, before), else: :ok
  end

  defp date_marks(bin, rows, before) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Only a finished title is dated this way: one still in progress has the time laev last saw
    # it, or none, and a started show is not "watched today" for having appeared.
    arrived =
      for {type, id, _, _, _, _, _, _, false, "finished", _} <- rows,
          not MapSet.member?(before, {type, id}),
          do: {type, id}

    # A person marks a few titles between two looks. Hundreds at once is a catalogue arriving —
    # an imported TMDB or IMDb history — and stamping them all "now" files years of watching under
    # today (it did, on 2026-10-29: 535 titles). They stay undated instead, which is the truth.
    if length(arrived) <= @marks_per_look do
      for {type, id} <- arrived do
        Repo.query!(
          "insert into roki_watch_dates (user_uuid, type, id, watched_at) values ($1, $2, $3, $4) on conflict (user_uuid, type, id) do nothing",
          [bin, type, id, now]
        )
      end
    end

    :ok
  end

  # The dates the owner set, laid back over what the rebuild just wrote.
  defp apply_dates(bin) do
    Repo.query!(
      """
      update roki_watched w set at = d.watched_at, dated = true
        from roki_watch_dates d
       where w.user_uuid = $1 and d.user_uuid = w.user_uuid and d.type = w.type and d.id = w.id
      """,
      [bin]
    )
  end

  @doc "Lay the owner's dates over the finished titles again (after anything that rewrote them)."
  def reapply_dates(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    apply_dates(bin)
    :ok
  end

  @doc """
  When this account says it watched each *season*: `%{{type, id, season} => unix}`.

  Separate from `watch_dates/1` because laev has no answer to give here — a show is one row in
  its watched list however many of its seasons were watched years apart.
  """
  def season_dates(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} =
      Repo.query!("select type, id, season, at from roki_season_dates where user_uuid = $1", [bin])

    Map.new(rows, fn [type, id, season, at] ->
      {{type, id, season}, at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()}
    end)
  end

  @doc "Say when one season was watched. A `nil` date takes the answer back."
  def set_season_date(uuid, type, id, season, nil)
      when is_binary(type) and is_integer(id) and is_integer(season) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    Repo.query!(
      "delete from roki_season_dates where user_uuid = $1 and type = $2 and id = $3 and season = $4",
      [bin, type, id, season]
    )

    :ok
  end

  def set_season_date(uuid, type, id, season, %Date{} = date)
      when is_binary(type) and is_integer(id) and is_integer(season) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    # Midday, so a day is the same day whichever way a timezone leans.
    at = NaiveDateTime.new!(date, ~T[12:00:00])
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.query!(
      "insert into roki_season_dates (user_uuid, type, id, season, at, inserted_at, updated_at) " <>
        "values ($1, $2, $3, $4, $5, $6, $6) " <>
        "on conflict (user_uuid, type, id, season) do update set at = excluded.at, updated_at = excluded.updated_at",
      [bin, type, id, season, at, now]
    )

    :ok
  end

  @doc """
  When this account says it watched each title, for the ones where it has said so: `%{{type,
  id} => unix}`.

  The watched page can give a title a date — a film found years after it was seen goes back
  where it belongs — and that date is this account's own answer, which is not the same as when
  anything was played on a device. Only rows carrying a real date are here; the rest have
  nothing to say and are left to laev.
  """
  def watch_dates(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} =
      Repo.query!("select type, id, at from roki_watched where user_uuid = $1 and dated", [bin])

    Map.new(rows, fn [type, id, at] ->
      {{type, id}, at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()}
    end)
  end

  defp read_watched(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} =
      Repo.query!(
        "select w.type, w.id, w.tmdb_type, w.tmdb_id, w.season, w.title, w.anime, w.at, w.dated, w.status, w.note, t.genres from roki_watched w left join roki_titles t on t.type = w.tmdb_type and t.id = w.tmdb_id where w.user_uuid = $1 order by w.dated desc, w.at desc",
        [bin]
      )

    items =
      Enum.map(rows, fn [type, id, tt, tid, season, title, anime, at, dated, status, note, genres] ->
        %{
          key: "#{type}:#{id}",
          type: tt,
          id: tid,
          mal_id: if(type == "mal", do: id),
          season: season,
          title: title,
          poster: nil,
          anime: anime,
          at: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(),
          dated?: dated,
          status: status,
          note: note,
          # TMDB's genre ids, once read (`Roki.Genres`); nil until then.
          genres: genres
        }
      end)

    items = date_from_seasons(items, uuid)

    cards = Roki.Titles.cards(for i <- items, do: card_key(i))

    items =
      Enum.map(items, fn i ->
        card = cards[card_key(i)] || %{}

        i
        |> Map.put(:year, card[:year])
        |> Map.merge(%{poster: card[:poster], title: i.title || card[:title]})
      end)

    # A season of a show is drawn with that season's poster, not the show's: a tier list of the
    # seven parts of JoJo is seven pictures, not one seven times.
    Roki.SeasonPosters.apply(items, uuid)
  end

  # A show watched a season or two and not finished has no date of its own — laev keeps none for it
  # — but the owner may have said when each season was watched (`set_season_date/5`). Its date is
  # the latest of those: the day the last season they watched was watched.
  defp date_from_seasons(items, uuid) do
    latest =
      Enum.reduce(season_dates(uuid), %{}, fn {{type, id, _season}, at}, acc ->
        Map.update(acc, {type, id}, at, &max(&1, at))
      end)

    if latest == %{} do
      items
    else
      Enum.map(items, fn
        %{dated?: false, type: type, id: id} = i when is_map_key(latest, {type, id}) ->
          %{i | at: latest[{type, id}], dated?: true}

        i ->
          i
      end)
    end
  end

  # A title's card is TMDB's; an anime with no TMDB title has MyAnimeList's, under its MAL id.
  defp card_key(%{type: nil, mal_id: mal}) when is_integer(mal), do: {"mal", mal}
  defp card_key(i), do: {i.type, i.id}

  @doc """
  Posters for the shown rows that have none yet, by {type, id}: read from TMDB through laev
  (one read each, once), and kept in the title store so the next look is a lookup.
  """
  def posters(uuid, items) do
    found = Roki.Laev.completed_posters(uuid, items)

    Roki.Titles.remember_later(
      for %{type: type, id: id, title: title} <- items,
          poster = found[{type, id}],
          do: %{type: type, id: id, title: title, poster: poster}
    )

    # An anime no TMDB title stands for: MyAnimeList's own picture, kept under the MAL id.
    mal =
      for %{type: nil, mal_id: mal, poster: nil} <- items, is_integer(mal), reduce: %{} do
        acc ->
          case mal_picture(uuid, mal) do
            nil -> acc
            url -> Map.put(acc, {"mal", mal}, url)
          end
      end

    names = Map.new(items, fn i -> {i[:mal_id], i[:title]} end)

    Roki.Titles.remember_later(
      for {{"mal", id}, url} <- mal,
          do: %{type: "mal", id: id, title: names[id] || "MAL #{id}", poster: url}
    )

    Map.merge(found, mal)
  end

  # MyAnimeList's picture of an anime (the main one), read with the site's client id; nil when
  # there is none or MyAnimeList is not set up.
  defp mal_picture(uuid, mal_id) do
    Roki.Laev.run(uuid, fn ->
      with client when is_binary(client) and client != "" <- Laev.MAL.client_id(),
           {:ok, %{status: 200, body: %{"main_picture" => %{} = pic}}} <-
             Req.get("https://api.myanimelist.net/v2/anime/#{mal_id}",
               headers: [{"x-mal-client-id", client}],
               params: [fields: "main_picture"],
               retry: false,
               receive_timeout: 10_000
             ) do
        pic["medium"] || pic["large"]
      else
        _ -> nil
      end
    end)
  rescue
    _ -> nil
  end

  @doc "The kinds a profile's history is filtered by."
  def kinds, do: [all: "All", movie: "Movies", tv: "Shows", anime: "Anime"]

  @doc "The kind named in an address, else :all."
  def kind(value),
    do: Enum.find_value(kinds(), :all, fn {k, _} -> Atom.to_string(k) == value && k end)

  @doc "The order named in an address: :top for the owner's ratings, :oldest for the first watched, else :latest."
  def sort("top"), do: :top
  def sort("oldest"), do: :oldest
  def sort(_), do: :latest

  @doc """
  The history as the page shows it: of one `kind` (`:all`, `:movie`, `:tv`, `:anime`), in
  `order` (`:latest` — newest first — `:oldest` — the first watched first, the undated last — or
  `:top` — the owner's own rating first, the unrated last),
  and only those rated `rating` when it is a whole number 1 to 10 (a 9 takes 9 to 9.9; `true` is a 10, as the old tens filter was). Each item gets its `score` (nil when unrated) and, in the
  rating order, the score as its badge.
  """
  def arrange(items, ratings, kind, order, rating \\ nil) do
    rating = rating_filter(rating)

    items
    |> Enum.filter(&of_kind?(&1, kind))
    |> Enum.map(&Map.put(&1, :score, score_of(ratings, &1)))
    |> Enum.filter(fn i ->
      case rating do
        nil -> true
        # Only what has no rating yet — to find what is left to rate.
        :none -> i.score == nil
        n -> i.score != nil and trunc(i.score) == n
      end
    end)
    |> then(fn list ->
      case order do
        :top ->
          list
          |> Enum.sort_by(&{if(&1.score, do: 0, else: 1), -(&1.score || 0), -&1.at})
          |> Enum.map(&Map.put(&1, :badge, badge(&1.score)))

        :oldest ->
          Enum.sort_by(list, &{if(&1.dated?, do: 0, else: 1), &1.at})

        _ ->
          list
      end
    end)
  end

  defp rating_filter(true), do: 10
  defp rating_filter(:none), do: :none
  defp rating_filter(n) when is_integer(n) and n in 1..10, do: n
  defp rating_filter(_), do: nil

  @doc "A rating filter from an address: `\"7\"` is 7, `\"none\"` is the unrated, anything else is no filter."
  def rating_param("none"), do: :none

  def rating_param(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n in 1..10 -> n
      _ -> nil
    end
  end

  defp of_kind?(_item, :all), do: true
  defp of_kind?(item, :anime), do: item.anime
  defp of_kind?(item, :manga), do: item.type == "manga"
  defp of_kind?(item, kind), do: not item.anime and item.type == Atom.to_string(kind)

  defp badge(nil), do: nil
  defp badge(score), do: "★ " <> score_text(score)

  @doc "A score as the page writes it: `10`, `8.5`."
  def score_text(score) when is_float(score) do
    if score == Float.round(score),
      do: Integer.to_string(trunc(score)),
      else: :erlang.float_to_binary(score, decimals: 1)
  end

  def score_text(score), do: to_string(score)

  # An anime is rated on MyAnimeList when it has an entry there (the site rates it there too);
  # everything else on TMDB.
  @doc "The rating a `ratings/1` map holds for a title (an item with `type`, `id` and maybe `mal_id`), or nil."
  def score_for(ratings, item), do: score_of(ratings, item)

  defp score_of(ratings, %{mal_id: mal} = item) when is_integer(mal),
    do: ratings[{"mal", mal}] || ratings[{item.type, item.id}]

  defp score_of(ratings, item), do: ratings[{item.type, item.id}]

  @doc """
  What this person has read, in the shape `history/1` returns, so the shelf picker and
  `arrange/5` work on it unchanged: one entry per saved series, `type: "manga"` with the
  reader's own id, and its cover as the poster.

  The score is the tier they put it in on their tierlist, through the same mapping the reader
  pushes to MyAnimeList (S is 10, A is 9, and so on) — manga is not rated out of ten anywhere
  else here, and a tierlist is the rating this person actually gave it.
  """
  def read_history(uuid) when is_binary(uuid) do
    for m <- Roki.Manga.Library.list_read_history(uuid) do
      %{
        type: "manga",
        id: m.id,
        source: m.source,
        slug: m.slug,
        title: m.title,
        poster: manga_poster(m),
        anime: false,
        seen: false,
        at: DateTime.to_unix(DateTime.from_naive!(m.updated_at, "Etc/UTC")),
        tier: m.tier
      }
    end
  end

  # The ratings map `arrange/5` wants, built from the entries themselves.
  defp manga_scores(items) do
    for i <- items,
        score = Roki.Manga.Trackers.MAL.tier_score(i.tier),
        into: %{},
        do: {{"manga", i.id}, score * 1.0}
  end

  # The media library's copy when there is one, else the source's own address through this
  # site, which carries the headers the source asks for.
  defp manga_poster(%{cover_file_uuid: uuid}) when is_binary(uuid) and uuid != "",
    do: PhoenixKit.Modules.Storage.URLSigner.signed_url(uuid, "medium")

  defp manga_poster(%{cover_url: url}) when is_binary(url) and url != "",
    do: "/manga/proxy/image?url=" <> URI.encode_www_form(url)

  defp manga_poster(_), do: nil

  # The series behind manga favourites, by the reader's id.
  defp manga_cards([]), do: %{}

  defp manga_cards(items) do
    for m <- Roki.Manga.Library.list_saved_by_ids(Enum.map(items, & &1.id)),
        into: %{},
        do: {m.id, %{source: m.source, slug: m.slug, title: m.title, poster: manga_poster(m)}}
  end

  # ── the favourites ────────────────────────────────────────────────

  @shelves [movie: "Movies", tv: "Shows", anime: "Anime", manga: "Manga"]
  @top 10

  @doc "The shelves a profile has, in order: `[movie: \"Movies\", tv: \"Shows\", anime: \"Anime\", manga: \"Manga\"]`."
  def shelves, do: @shelves

  @doc "A shelf named in an event or address, else nil."
  def shelf(value),
    do: Enum.find_value(@shelves, fn {k, _} -> Atom.to_string(k) == value && k end)

  @doc "How many a shelf holds."
  def top, do: @top

  @doc "Whether a shelf shows its places as numbers (`profile` as `get/1` returns it)."
  def ranked?(%{ranked: ranked}, kind) when is_list(ranked), do: Atom.to_string(kind) in ranked
  def ranked?(_profile, _kind), do: false

  @doc "Turn the numbers on a shelf on or off: `{:ok, profile}`."
  def set_ranked(uuid, kind, on?)
      when kind in [:movie, :tv, :anime, :manga] and is_boolean(on?) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    current = get(uuid).ranked
    shelf = Atom.to_string(kind)
    next = if on?, do: Enum.uniq(current ++ [shelf]), else: List.delete(current, shelf)

    Repo.query!(
      """
      insert into roki_profiles (user_uuid, ranked, inserted_at, updated_at) values ($1, $2, $3, $3)
      on conflict (user_uuid) do update set ranked = excluded.ranked, updated_at = excluded.updated_at
      """,
      [bin, next, now]
    )

    {:ok, get(uuid)}
  end

  @doc """
  The favourites of a user, by shelf: `%{movie: [item], tv: [...], anime: [...], manga: [...]}`,
  each item `%{type:, id:, mal_id:, title:, poster:, position:}` in the owner's order, with
  the poster from the title store.
  """
  def favorites(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} =
      Repo.query!(
        "select kind, position, type, id, title from roki_favorites where user_uuid = $1 order by kind, position",
        [bin]
      )

    items =
      for [kind, position, type, id, title] <- rows,
          do: %{kind: kind, position: position, type: type, id: id, title: title}

    cards =
      items
      |> Enum.reject(&(&1.type == "manga"))
      |> Enum.map(&{&1.type, &1.id})
      |> Roki.Titles.cards()

    manga = manga_cards(Enum.filter(items, &(&1.type == "manga")))

    items =
      Enum.map(items, fn
        %{type: "manga"} = i ->
          m = manga[i.id] || %{}

          %{
            type: "manga",
            id: i.id,
            source: m[:source],
            slug: m[:slug],
            title: m[:title] || i.title,
            poster: m[:poster],
            position: i.position,
            badge: "##{i.position}",
            kind: i.kind,
            anime: false
          }

        i ->
          card = cards[{i.type, i.id}] || %{}
          {type, id} = if i.type == "mal", do: {nil, nil}, else: {i.type, i.id}

          %{
            type: type,
            id: id,
            mal_id: if(i.type == "mal", do: i.id),
            title: i.title || card[:title],
            poster: card[:poster],
            position: i.position,
            badge: "##{i.position}",
            kind: i.kind
          }
      end)

    for {kind, _} <- @shelves,
        into: %{},
        do: {kind, Enum.filter(items, &(&1.kind == Atom.to_string(kind)))}
  end

  @doc """
  Put a title on a shelf, at the end: `{:ok, favorites}`, or `{:error, message}` when the
  shelf is full or the title is on a shelf already. `key` is `{"movie" | "tv" | "mal", id}`.
  """
  def add_favorite(uuid, kind, {type, id}, title)
      when kind in [:movie, :tv, :anime, :manga] and is_integer(id) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    shelf = Atom.to_string(kind)

    %{rows: [[n]]} =
      Repo.query!("select count(*) from roki_favorites where user_uuid = $1 and kind = $2", [
        bin,
        shelf
      ])

    %{rows: [[taken]]} =
      Repo.query!(
        "select count(*) from roki_favorites where user_uuid = $1 and type = $2 and id = $3",
        [bin, type, id]
      )

    cond do
      taken > 0 ->
        {:error, "That one is on a shelf already."}

      n >= @top ->
        {:error, "The shelf holds #{@top}. Take one off first."}

      true ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.query!(
          "insert into roki_favorites (user_uuid, kind, position, type, id, title, inserted_at) values ($1, $2, $3, $4, $5, $6, $7)",
          [bin, shelf, n + 1, type, id, title, now]
        )

        {:ok, favorites(uuid)}
    end
  end

  @doc "Take a title off its shelf; the rest close up. `{:ok, favorites}`."
  def remove_favorite(uuid, {type, id}) when is_integer(id) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    Repo.transaction(fn ->
      case Repo.query!(
             "delete from roki_favorites where user_uuid = $1 and type = $2 and id = $3 returning kind",
             [bin, type, id]
           ) do
        %{rows: [[kind]]} -> renumber(bin, kind)
        _ -> :ok
      end
    end)

    {:ok, favorites(uuid)}
  end

  @doc "Move a title one place up or down its shelf (`:up` | `:down`). `{:ok, favorites}`."
  def move_favorite(uuid, {type, id}, dir) when dir in [:up, :down] and is_integer(id) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    Repo.transaction(fn ->
      case Repo.query!(
             "select kind, position from roki_favorites where user_uuid = $1 and type = $2 and id = $3",
             [bin, type, id]
           ) do
        %{rows: [[kind, pos]]} ->
          other = if dir == :up, do: pos - 1, else: pos + 1
          # Swap through a place no row has, since each place is taken once.
          Repo.query!(
            "update roki_favorites set position = 0 where user_uuid = $1 and kind = $2 and position = $3",
            [bin, kind, other]
          )

          Repo.query!(
            "update roki_favorites set position = $3 where user_uuid = $1 and kind = $2 and position = $4",
            [bin, kind, other, pos]
          )

          Repo.query!(
            "update roki_favorites set position = $3 where user_uuid = $1 and kind = $2 and position = 0",
            [bin, kind, pos]
          )

          renumber(bin, kind)

        _ ->
          :ok
      end
    end)

    {:ok, favorites(uuid)}
  end

  # Places 1..n again, in the order they are.
  defp renumber(bin, kind) do
    %{rows: rows} =
      Repo.query!(
        "select type, id from roki_favorites where user_uuid = $1 and kind = $2 order by position",
        [bin, kind]
      )

    # Through places no row has first, so no two rows share one on the way.
    Repo.query!(
      "update roki_favorites set position = position + 1000 where user_uuid = $1 and kind = $2",
      [bin, kind]
    )

    rows
    |> Enum.with_index(1)
    |> Enum.each(fn {[type, id], n} ->
      Repo.query!(
        "update roki_favorites set position = $4 where user_uuid = $1 and kind = $2 and type = $3 and id = $5",
        [bin, kind, type, n, id]
      )
    end)

    :ok
  end

  @doc """
  What may go on a shelf: the user's watched titles of that kind (`history/1` filtered), with
  the ones already on a shelf marked `on_shelf: true`, the newest first. Manga has none yet.
  """
  def candidates(uuid, kind, favorites \\ nil) when kind in [:movie, :tv, :anime, :manga] do
    favs = favorites || favorites(uuid)

    taken =
      for {_, items} <- favs,
          i <- items,
          into: MapSet.new(),
          do: {i.type || "mal", i.id || i.mal_id}

    uuid
    |> history()
    |> Enum.filter(&of_kind?(&1, kind))
    |> Enum.map(fn i ->
      Map.put(i, :on_shelf, MapSet.member?(taken, {i.type || "mal", i.id || i.mal_id}))
    end)
  end

  @doc """
  The list a shelf's picker shows: the user's watched titles of that kind and only that kind,
  their own highest rating first (the unrated after, newest first), each with `key` (the
  string a click names it by) and `on_shelf`. Nothing of another kind can be in it, so nothing
  of another kind can be put on the shelf.
  """
  def picker(uuid, kind, favorites \\ nil) when kind in [:movie, :tv, :anime, :manga] do
    favs = favorites || favorites(uuid)
    taken = for {_, items} <- favs, i <- items, into: MapSet.new(), do: favorite_key(i)

    items = if kind == :manga, do: read_history(uuid), else: history(uuid)
    rates = if kind == :manga, do: manga_scores(items), else: ratings(uuid)

    items
    |> arrange(rates, kind, :top)
    |> Enum.map(fn i ->
      {type, id} = favorite_key(i)
      i |> Map.put(:key, "#{type}:#{id}") |> Map.put(:on_shelf, MapSet.member?(taken, {type, id}))
    end)
  end

  @doc "A click's key (`\"movie:603\"`, `\"mal:5114\"`) as `{type, id}`, or nil."
  def parse_key(key) when is_binary(key) do
    with [type, id] when type in ["movie", "tv", "mal", "manga"] <-
           String.split(key, ":", parts: 2),
         {n, ""} <- Integer.parse(id) do
      {type, n}
    else
      _ -> nil
    end
  end

  def parse_key(_), do: nil

  @doc """
  Put several titles on a shelf at once, at the end, in the order given: `{:ok, favorites,
  added}`. Only titles in the shelf's own picker list count — a film cannot go on the shows
  shelf — and only as many as the shelf has places left; `{:error, message}` when none can.
  """
  def add_favorites(uuid, kind, keys)
      when kind in [:movie, :tv, :anime, :manga] and is_list(keys) do
    favs = favorites(uuid)
    left = @top - length(favs[kind] || [])
    wanted = keys |> Enum.map(&parse_key/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    allowed =
      for i <- picker(uuid, kind, favs), not i.on_shelf, into: %{}, do: {favorite_key(i), i.title}

    chosen = wanted |> Enum.filter(&Map.has_key?(allowed, &1)) |> Enum.take(left)

    cond do
      left <= 0 ->
        {:error, "The shelf holds #{@top}. Take one off first."}

      chosen == [] ->
        {:error, "None of those can go on this shelf."}

      true ->
        Enum.each(chosen, fn key -> add_favorite(uuid, kind, key, allowed[key]) end)
        {:ok, favorites(uuid), length(chosen)}
    end
  end

  def add_favorites(_uuid, _kind, _keys), do: {:error, "None of those can go on this shelf."}

  @doc """
  Put a shelf in the order a drag left it: `ordered` is the keys (`\"movie:603\"`) as shown.
  `{:ok, favorites}`, or `{:error, favorites}` — the shelf as it is — when the keys are not
  exactly the shelf's titles.
  """
  def reorder_favorites(uuid, kind, ordered)
      when kind in [:movie, :tv, :anime, :manga] and is_list(ordered) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    shelf = Atom.to_string(kind)
    keys = Enum.map(ordered, &parse_key/1)

    %{rows: rows} =
      Repo.query!("select type, id from roki_favorites where user_uuid = $1 and kind = $2", [
        bin,
        shelf
      ])

    current = for [t, i] <- rows, into: MapSet.new(), do: {t, i}

    if nil not in keys and length(keys) == MapSet.size(current) and MapSet.new(keys) == current do
      Repo.transaction(fn ->
        Repo.query!(
          "update roki_favorites set position = position + 1000 where user_uuid = $1 and kind = $2",
          [bin, shelf]
        )

        keys
        |> Enum.with_index(1)
        |> Enum.each(fn {{t, i}, n} ->
          Repo.query!(
            "update roki_favorites set position = $4 where user_uuid = $1 and kind = $2 and type = $3 and id = $5",
            [bin, shelf, t, n, i]
          )
        end)
      end)

      {:ok, favorites(uuid)}
    else
      {:error, favorites(uuid)}
    end
  end

  @doc "The key a watched item is kept under on a shelf: TMDB's type and id, or MyAnimeList's."
  def favorite_key(%{type: nil, mal_id: mal}) when is_integer(mal), do: {"mal", mal}
  def favorite_key(%{type: type, id: id}), do: {type, id}

  # ── the ratings ───────────────────────────────────────────────────

  @doc "The user's ratings as copied here, by {type, id}: `{\"movie\", 10331}` to 8.5, `{\"mal\", 5114}` to 9.0."
  def ratings(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} =
      Repo.query!("select type, id, score from roki_ratings where user_uuid = $1", [bin])

    Map.new(rows, fn [type, id, score] -> {{type, id}, score * 1.0} end)
  end

  # ── season ratings ─────────────────────────────────────────────────

  @doc """
  What this account gave each season of a show on Roki: `%{2 => 8.5}`. TMDB only rates a show as a
  whole, so these never leave the site.
  """
  def season_ratings(uuid, tmdb_id) when is_binary(uuid) and is_integer(tmdb_id) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} =
      Repo.query!(
        "select season, score from roki_season_ratings where user_uuid = $1 and tmdb_id = $2",
        [bin, tmdb_id]
      )

    Map.new(rows, fn [season, score] -> {season, score * 1.0} end)
  end

  def season_ratings(_uuid, _tmdb_id), do: %{}

  @doc """
  A season's rating: its own when it has one (`{:own, 8.5}`), else the show's (`{:seeded, 7.0}`),
  else `:none`. Nothing is copied: a season never rated follows the show's rating.
  """
  def season_rating(season_ratings, season, show_rating) do
    case {Map.get(season_ratings, season), show_rating} do
      {score, _} when is_number(score) -> {:own, score}
      {_, score} when is_number(score) -> {:seeded, score}
      _ -> :none
    end
  end

  @doc "Set a season's rating (0.5–10 in half steps)."
  def put_season_rating(uuid, tmdb_id, season, score) when is_number(score) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    score = (score * 2) |> round() |> max(1) |> min(20) |> Kernel./(2)

    Repo.query!(
      """
      insert into roki_season_ratings (user_uuid, tmdb_id, season, score) values ($1, $2, $3, $4)
      on conflict (user_uuid, tmdb_id, season) do update set score = excluded.score, rated_at = now()
      """,
      [bin, tmdb_id, season, score]
    )

    {:ok, score}
  end

  @doc "Take a season's own rating back: it reads as the show's again."
  def clear_season_rating(uuid, tmdb_id, season) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    Repo.query!(
      "delete from roki_season_ratings where user_uuid = $1 and tmdb_id = $2 and season = $3",
      [bin, tmdb_id, season]
    )

    :ok
  end

  @doc """
  How many titles of each kind the account rated at each score: `%{"movie" => %{7.5 => 3, ...},
  "tv" => ..., "mal" => ...}` (anime are MyAnimeList entries). Read from the site's copy.
  """
  def rating_counts(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} =
      Repo.query!(
        "select type, score, count(*) from roki_ratings where user_uuid = $1 and score > 0 group by type, score",
        [bin]
      )

    # A season rated on its own is a rating too, counted with the shows.
    %{rows: season_rows} =
      Repo.query!(
        "select score, count(*) from roki_season_ratings where user_uuid = $1 group by score",
        [bin]
      )

    rows = rows ++ for [score, n] <- season_rows, do: ["tv", score, n]

    Enum.reduce(rows, %{}, fn [type, score, n], acc ->
      Map.update(acc, type, %{(score * 1.0) => n}, fn by ->
        Map.update(by, score * 1.0, n, &(&1 + n))
      end)
    end)
  end

  @doc """
  The bars of a rating breakdown for the kinds in `kinds` (`nil` = all): `%{bars: [{score, count}],
  total:, average:, top:}`; bars from the lowest score used to 10, half points kept only when the
  account gives them. `nil` when nothing was rated.
  """
  def rating_breakdown(counts, kinds \\ nil) do
    merged =
      counts
      |> Enum.filter(fn {type, _} -> kinds == nil or type in kinds end)
      |> Enum.reduce(%{}, fn {_type, by}, acc -> Map.merge(acc, by, fn _, a, b -> a + b end) end)

    total = merged |> Map.values() |> Enum.sum()

    if total == 0 do
      nil
    else
      halves? = Enum.any?(merged, fn {score, _} -> score != Float.round(score) end)
      step = if halves?, do: 0.5, else: 1.0
      low = merged |> Map.keys() |> Enum.min() |> min(10.0)
      count = trunc((10.0 - low) / step)

      bars = for i <- 0..count, score = 10.0 - i * step, do: {score, Map.get(merged, score, 0)}
      bars = Enum.reverse(bars)
      sum = Enum.reduce(merged, 0.0, fn {score, n}, acc -> acc + score * n end)

      %{
        bars: bars,
        total: total,
        average: Float.round(sum / total, 1),
        top: bars |> Enum.max_by(&elem(&1, 1)) |> elem(0)
      }
    end
  end

  @doc """
  What this account rated at each score, newest first, up to `per` a score (six: the sheet's row) — for the rating
  sheet's shelf: `%{"8.5" => [%{type, id, title, year, poster}]}`, the keys as the slider says
  them (`score_key/1`). One kind at a time (`type`: films, shows or anime — TMDB's order is
  only known within a kind), the title at `except` left out. Newest is a date where there is
  one (MyAnimeList, a rating made here), else the place in TMDB's list (`seq`).
  """
  def rated_like(uuid, type, except \\ nil, per \\ 6)
      when is_binary(uuid) and type in ["movie", "tv", "mal"] do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} =
      Repo.query!(
        "select id, score from roki_ratings where user_uuid = $1 and type = $2 order by rated_at desc nulls last, seq desc nulls last, id desc",
        [bin, type]
      )

    picked =
      rows
      |> Enum.reject(fn [id, _] -> id == except end)
      |> Enum.group_by(fn [_, score] -> score * 1.0 end, fn [id, _] -> id end)
      |> Map.new(fn {score, ids} -> {score, Enum.take(ids, per)} end)

    cards = Roki.Titles.cards(for {_, ids} <- picked, id <- ids, do: {type, id})

    Map.new(picked, fn {score, ids} ->
      {score_key(score),
       Enum.map(ids, fn id ->
         c = cards[{type, id}] || %{}
         %{type: type, id: id, title: c[:title], year: c[:year], poster: c[:poster]}
       end)}
    end)
  end

  @doc "A score as the rating slider says it: 8 → \"8\", 8.5 → \"8.5\"."
  def score_key(score) when is_number(score) do
    if score == trunc(score),
      do: Integer.to_string(trunc(score)),
      else: :erlang.float_to_binary(score * 1.0, decimals: 1)
  end

  @doc """
  One rating from the site's copy: `{:ok, score}`; `:none` when the copy is recent (a day) and
  has no rating of it; `:unknown` when the copy is old or was never made, so the source should
  be asked.
  """
  def rating(uuid, {type, id}) when is_binary(uuid) and is_binary(type) and is_integer(id) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    case Repo.query!(
           "select score from roki_ratings where user_uuid = $1 and type = $2 and id = $3",
           [bin, type, id]
         ) do
      %{rows: [[score]]} ->
        {:ok, score * 1.0}

      _ ->
        case get(uuid).ratings_synced_at do
          %NaiveDateTime{} = at ->
            if NaiveDateTime.diff(NaiveDateTime.utc_now(), at) < 24 * 3600,
              do: :none,
              else: :unknown

          _ ->
            :unknown
        end
    end
  end

  @doc """
  A rating made or taken back on the site, noted here at once: `target` is `{"mal", id}` or
  `{"movie" | "tv", id}`, `score` the rating or nil for none. `local: true` marks a rating that
  exists only on Roki (no TMDB account to send it to), which a refresh from TMDB never replaces.
  """
  def note_rating(uuid, target, score, opts \\ [])

  def note_rating(uuid, {type, id}, score, opts)
      when is_binary(uuid) and is_binary(type) and is_integer(id) do
    local = Keyword.get(opts, :local, false)
    {:ok, bin} = Ecto.UUID.dump(uuid)

    if is_number(score) and score > 0 do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # After everything of its type: the newest (`seq`, see `rated_like/4`).
      Repo.query!(
        """
        insert into roki_ratings (user_uuid, type, id, score, rated_at, local, seq)
        values ($1, $2, $3, $4, $5, $6, (select coalesce(max(seq), 0) + 1 from roki_ratings where user_uuid = $1 and type = $2))
        on conflict (user_uuid, type, id) do update
          set score = excluded.score, rated_at = excluded.rated_at, local = excluded.local, seq = excluded.seq
        """,
        [bin, type, id, score * 1.0, now, local]
      )
    else
      Repo.query!("delete from roki_ratings where user_uuid = $1 and type = $2 and id = $3", [
        bin,
        type,
        id
      ])
    end

    :ok
  end

  def note_rating(_uuid, _target, _score, _opts), do: :ok

  @doc """
  Copy the user's ratings here from TMDB (their account's rated films and shows) and
  MyAnimeList (the scores on their list), at most once an hour: a long-standing TMDB account
  is many pages. One copy at a time, and an hour counts from a copy that finished — a page
  that goes away half-way through leaves the next one to do it. `:ok`, `:recent` when done
  lately, `:not_connected` without laev.
  """
  def refresh_ratings(uuid) when is_binary(uuid) do
    cond do
      not Roki.Laev.connected?(uuid) ->
        :not_connected

      TTLCache.cached?({:ratings_refresh, uuid}) ->
        :recent

      true ->
        TTLCache.fetch({:ratings_refresh, uuid}, @ratings_every_s, fn ->
          replace_ratings(uuid, read_ratings(uuid))
          {:ok, :done}
        end)

        :ok
    end
  end

  defp read_ratings(uuid) do
    Roki.Laev.run(uuid, fn ->
      tmdb =
        if Laev.Tmdb.account?() do
          # TMDB lists them in the order they were made (oldest first), with no dates: the
          # place in the list is kept as `seq`, so newest-first is a sort on it.
          for {kind, type} <- [{"movies", "movie"}, {"tv", "tv"}],
              {r, seq} <- Enum.with_index(Laev.Tmdb.rated(kind)),
              is_integer(r["id"]) and is_number(r["rating"]) do
            {type, r["id"], r["rating"] * 1.0, nil, seq}
          end
        else
          []
        end

      mal =
        if Laev.MAL.authenticated?() do
          case Laev.MAL.list() do
            {:ok, entries} ->
              # The list carries the names (no pictures): kept, so a shelf can say them.
              Roki.Titles.remember_later(
                for %{mal_id: id, title: name} <- entries, do: %{type: "mal", id: id, title: name}
              )

              for %{mal_id: id, score: score} = e <- entries, is_integer(score) and score > 0 do
                {"mal", id, score * 1.0, e[:updated] && DateTime.from_unix!(e[:updated]), nil}
              end

            _ ->
              []
          end
        else
          []
        end

      tmdb ++ mal
    end)
  end

  # The copy is rewritten from what TMDB and MyAnimeList say — unless that is smaller than the
  # copy it would replace by more than a few ratings. Laev's TMDB paging hands back whatever pages it got when one
  # fails, with no sign that it stopped early, so a short answer is far likelier to be a failed
  # read than ratings taken back; on 2026-10-27 one such read erased a few hundred of a user's
  # ratings. A short answer is merged in (what it holds is kept, nothing is deleted) and the copy
  # is not marked fresh, so the next look tries again.
  @doc "Drop the copy of this account's TMDB ratings (films and shows); MyAnimeList ones stay."
  def forget_tmdb_ratings(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    Repo.query!(
      "delete from roki_ratings where user_uuid = $1 and type in ('movie', 'tv') and not local",
      [bin]
    )

    TTLCache.delete({:ratings_refresh, uuid})
    :ok
  end

  defp replace_ratings(uuid, rows) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    rows = Enum.uniq_by(rows, fn {type, id, _, _, _} -> {type, id} end)

    {:ok, outcome} =
      Repo.transaction(fn ->
        %{rows: [[old]]} =
          Repo.query!("select count(*) from roki_ratings where user_uuid = $1 and not local", [
            bin
          ])

        # A failed page costs twenty ratings, so anything more than a few fewer than the copy
        # already holds is taken for a failed read; a handful taken back on TMDB is not.
        partial? = old >= 20 and length(rows) < old - max(3, round(old * 0.005))

        if partial? do
          require Logger

          Logger.warning(
            "ratings read for #{uuid} returned #{length(rows)}, copy holds #{old}: merged, not replaced"
          )
        else
          Repo.query!("delete from roki_ratings where user_uuid = $1 and not local", [bin])
        end

        rows
        |> Enum.chunk_every(500)
        |> Enum.each(fn chunk ->
          {values, params} =
            chunk
            |> Enum.with_index()
            |> Enum.map_reduce([], fn {{type, id, score, at, seq}, i}, acc ->
              n = i * 5

              {"($1, $#{n + 2}, $#{n + 3}, $#{n + 4}, $#{n + 5}, $#{n + 6})",
               acc ++ [type, id, score, at, seq]}
            end)

          Repo.query!(
            "insert into roki_ratings (user_uuid, type, id, score, rated_at, seq) values " <>
              Enum.join(values, ", ") <>
              " on conflict (user_uuid, type, id) do update set score = excluded.score, rated_at = coalesce(excluded.rated_at, roki_ratings.rated_at), seq = coalesce(excluded.seq, roki_ratings.seq) where not roki_ratings.local",
            [bin | params]
          )
        end)

        unless partial? do
          Repo.query!(
            """
            insert into roki_profiles (user_uuid, ratings_synced_at, inserted_at, updated_at) values ($1, $2, $2, $2)
            on conflict (user_uuid) do update set ratings_synced_at = excluded.ratings_synced_at
            """,
            [bin, now]
          )
        end

        if partial?, do: :partial, else: :replaced
      end)

    outcome
  end
end
