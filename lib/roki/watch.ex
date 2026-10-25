defmodule Roki.Watch do
  @moduledoc """
  Everything between a poster and a playing video, composed from laev.

  Laev's terminal app does this inside its CLI (private functions); every piece it uses
  is public, so this is the same flow for a web page, in four steps:

    1. **Title** — TMDB details, normalised, and the names to search and accept
       (`title/3`, `episodes/4`).
    2. **Sources** — torrents for a film or an episode: Torrentio and ThePirateBay by IMDb
       id and name; Nyaa/AnimeTosho for anime. Public data, so one search is shared and
       cached (`sources/4`); the user's own debrid library is added per user
       (`with_library/3`).
    3. **Probe** — `Laev.Providers.probe_sources/2` asks Real-Debrid / TorBox which of them
       actually play, using that user's keys. Not shared: it is their account.
    4. **Play** — `start/4` remuxes the chosen release to HLS (ffmpeg) or hands over a
       direct link, and records where the user is (`Laev.Resume`, `Laev.Playback.progress`)
       so watching here updates history, stats and the shelf, and syncs to the terminal app.

  Functions that need a user's keys take `uuid` and run in that user's laev scope.
  """

  alias Laev.{Sources, Tmdb}
  alias Roki.TTLCache

  @details_ttl 12 * 60 * 60
  @episodes_ttl 6 * 60 * 60
  @sources_ttl 10 * 60

  # How many releases one probe round checks (laev's own page size).
  @probe_page 8
  @transcode_cap "1080p"
  @max_encoders 2

  # ── 1. the title ───────────────────────────────────────────────────

  @doc """
  `{:ok, title}` for a film or show — cached 12 hours, shared (it is public data).

  `title.search` is what to look for and `title.accept` every name a release may carry
  (laev's rule: accepting is free, searching costs a request per name).
  """
  def title(type, id, uuid \\ nil) when type in ~w(movie tv) and is_integer(id) do
    TTLCache.fetch({:title, 2, type, id}, @details_ttl, fn ->
      Roki.Laev.public(uuid, fn ->
        with {:ok, d} <- fetch_details(type, id) do
          Laev.AnimeMap.ensure()
          {:ok, normalize(type, d)}
        end
      end)
    end)
  end

  defp fetch_details("movie", id), do: Tmdb.movie(id)
  defp fetch_details("tv", id), do: Tmdb.tv(id)

  defp normalize(type, d) do
    date = d["release_date"] || d["first_air_date"]

    %{
      type: type,
      id: d["id"],
      title: d["title"] || d["name"],
      original_title: d["original_title"] || d["original_name"],
      tagline: blank(d["tagline"]),
      overview: blank(d["overview"]),
      year: Tmdb.year(date),
      date: date,
      poster: Tmdb.poster_url(d["poster_path"], "w500"),
      poster_path: d["poster_path"],
      backdrop: Tmdb.poster_url(d["backdrop_path"], "w1280"),
      vote: d["vote_average"],
      minutes: d["runtime"] || List.first(d["episode_run_time"] || []),
      genres: for(g <- d["genres"] || [], do: g["name"]),
      status: d["status"],
      imdb_id: Tmdb.imdb_id(d),
      language: d["original_language"],
      seasons: seasons(d),
      anime?: Laev.AnimeMap.anime?(type, d["id"]),
      vote_count: d["vote_count"],
      countries: for(c <- d["production_countries"] || [], do: c["name"]),
      studios: for(c <- d["production_companies"] || [], do: c["name"]),
      networks: for(n <- d["networks"] || [], do: n["name"]),
      spoken: for(l <- d["spoken_languages"] || [], do: l["english_name"] || l["name"]),
      episodes_total: d["number_of_episodes"],
      last_air_date: d["last_air_date"],
      search: title_variants(d)
    }
  end

  defp seasons(%{"seasons" => seasons}) when is_list(seasons) do
    list =
      for s <- seasons, is_integer(s["season_number"]) do
        %{
          number: s["season_number"],
          name: s["name"],
          episodes: s["episode_count"] || 0,
          air_date: s["air_date"]
        }
      end

    # Specials (season 0) only when there is nothing else.
    case Enum.reject(list, &(&1.number == 0)) do
      [] -> list
      regular -> regular
    end
  end

  defp seasons(_), do: []

  defp blank(v) when v in [nil, ""], do: nil
  defp blank(v), do: v

  # What to search for and what to accept — laev's rule, ported from its CLI.
  defp title_variants(d) do
    primary = d["title"] || d["name"]
    original = d["original_title"] || d["original_name"]
    regional = regional_titles(d)

    accept =
      primary
      |> Sources.acceptable_titles([original | Enum.map(regional, &elem(&1, 1))])
      |> clean_titles(primary)

    %{
      search: clean_titles([primary, second_query(primary, original, regional, accept)], primary),
      accept: accept
    }
  end

  defp regional_titles(d) do
    case d["alternative_titles"] do
      %{"titles" => titles} when is_list(titles) ->
        Enum.map(titles, &{&1["iso_3166_1"], &1["title"]})

      %{"results" => titles} when is_list(titles) ->
        Enum.map(titles, &{&1["iso_3166_1"], &1["title"]})

      _ ->
        []
    end
  end

  # The one other name worth a request: the original title, or a romanised alias when that
  # is in another script (an indexer's releases are ASCII).
  defp second_query(primary, original, regional, accept) do
    usable = fn t -> is_binary(t) and t in accept and t != primary and latin?(t) end

    cond do
      usable.(original) ->
        original

      alias_ =
          Enum.find_value(regional, fn {iso, t} -> iso in ["US", "GB"] and usable.(t) and t end) ->
        alias_

      true ->
        Enum.find_value(regional, fn {_iso, t} -> usable.(t) and t end)
    end
  end

  defp latin?(t) when is_binary(t), do: Sources.query_title(t) =~ ~r/[a-z]/i
  defp latin?(_), do: false

  defp clean_titles(titles, fallback) do
    case titles |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.uniq_by(&String.downcase/1) do
      [] -> [fallback]
      cleaned -> cleaned
    end
  end

  # ── the user's library: watched, saved for later, on hold ─────────────

  @doc """
  Where this title stands for this user: `%{saved?, held?, watched?, all_watched?}`.
  `watched?` is for a film; `all_watched?` for a series (every episode out so far has a mark).
  Anime is kept on MyAnimeList, so it has no hold here.
  """
  def library(uuid, title) do
    Roki.Laev.run(uuid, fn ->
      ctx = build_ctx(title, nil, nil)

      %{
        saved?: Laev.Watchlist.has?(title.type, title.id),
        held?: not title.anime? and Laev.Holds.held?(title.type, title.id),
        watched?: title.type == "movie" and Laev.Position.finished?(ctx),
        # "Completed": the series' own mark, which is what puts it in the Completed section.
        # Every episode watched without it is "caught up" — still on the watchlist.
        all_watched?: title.type == "tv" and completed?(title)
      }
    end)
  end

  # What makes a series completed, as laev keeps it: a mark on the show itself — separate from
  # its episodes, which only say what was watched — and for anime one on each MyAnimeList entry
  # (the entry is what the Completed list shows). A season MyAnimeList has no entry for gets the
  # show's mark as well, so the show cannot be completed with that season left out.
  defp title_marks(%{type: "tv"} = title) do
    show = %{type: "tv", tmdb_id: title.id, season: nil, episode: nil}

    if title.anime? do
      entries = for mal <- Laev.AnimeMap.mal_ids("tv", title.id), do: %{mal_id: mal}

      unmapped? =
        Enum.any?(aired_seasons(title), &(Laev.Anime.Parts.parts(title.id, &1.number) == []))

      if unmapped? or entries == [], do: [show | entries], else: entries
    else
      [show]
    end
  end

  defp title_marks(_title), do: []

  defp completed?(title) do
    case title_marks(title) do
      [] -> false
      marks -> Enum.all?(marks, &Laev.Position.finished?/1)
    end
  end

  defp set_completed(uuid, title, completed?) do
    Roki.Laev.run(uuid, fn ->
      for mark <- title_marks(title), do: Laev.Position.set_watched(mark, completed?)
    end)
  end

  # Unmarking an episode takes the series out of Completed; marking the last episode of an anime
  # entry completes that entry, as finishing it in the terminal does.
  defp follow_episodes(uuid, title, ctxs, true) do
    Roki.Laev.run(uuid, fn ->
      marks = Laev.Position.anime_marks()

      for mal <- ctxs |> Enum.map(& &1[:mal_id]) |> Enum.filter(&is_integer/1) |> Enum.uniq(),
          total = Laev.Anime.episodes(mal),
          is_integer(total) and total > 0 and Map.get(marks, mal, 0) >= total,
          do: Laev.Position.set_watched(%{mal_id: mal}, true)
    end)

    _ = title
  end

  defp follow_episodes(uuid, title, _ctxs, false), do: set_completed(uuid, title, false)

  defp aired_seasons(title) do
    today = Date.utc_today()

    Enum.filter(title.seasons, fn s ->
      s.number > 0 and is_binary(s.air_date) and
        match?({:ok, d} when d != nil, Date.from_iso8601(s.air_date)) and
        Date.compare(Date.from_iso8601!(s.air_date), today) != :gt
    end)
  end

  @doc """
  Where a title is rated; `entry` is the MyAnimeList entry of the season on screen (MAL rates
  by season, TMDB by show).

  Where a title is rated. Anime goes to MyAnimeList while an account is connected (the entry
  is the title's first season, or the film itself) and to TMDB otherwise; everything else is
  TMDB's. Call inside `Roki.Laev.run/2`: the answer depends on the user's own keys.

  `{:mal, mal_id}` or `:tmdb`.
  """
  def rating_target(title, entry \\ nil) do
    mal =
      if title.anime? and Laev.MAL.authenticated?() do
        case title.type do
          _ when is_integer(entry) ->
            entry

          # A season with no MyAnimeList entry: rated on TMDB, not under the first season's.
          _ when entry == :none ->
            nil

          "movie" ->
            Laev.AnimeMap.mal_id("movie", title.id, nil)

          _ ->
            Laev.Anime.Parts.first_entry(title.id)
        end
      end

    if is_integer(mal), do: {:mal, mal}, else: :tmdb
  end

  @doc """
  Your own rating of a title: `{provider, {:ok, 8.5 | nil}}` with `provider` `:tmdb` or `:mal`
  (MyAnimeList scores are whole numbers), or `{:tmdb, :no_account}` when no TMDB account is
  linked in laev (ratings are sent with a TMDB session, which laev holds).
  """
  def my_rating(uuid, title, entry \\ nil) do
    Roki.Laev.run(uuid, fn ->
      case rating_target(title, entry) do
        {:mal, mal} ->
          case Laev.MAL.list_status(mal) do
            %{score: n} when is_integer(n) and n > 0 -> {:mal, {:ok, n * 1.0}}
            _ -> {:mal, {:ok, nil}}
          end

        :tmdb ->
          if Laev.Tmdb.account?() do
            {:tmdb,
             {:ok,
              if(title.type == "movie",
                do: Laev.Tmdb.movie_rating(title.id),
                else: Laev.Tmdb.tv_rating(title.id)
              )}}
          else
            {:tmdb, :no_account}
          end
      end
    end)
  end

  @doc "Rate a title (TMDB: 0.5–10 in half steps; MyAnimeList: 1–10): `{:ok, rating}` or `{:error, why}`."
  def rate(uuid, title, value, entry \\ nil) do
    Roki.Laev.run(uuid, fn ->
      case rating_target(title, entry) do
        {:mal, mal} ->
          score = value |> round() |> max(1) |> min(10)

          case Laev.MAL.rate(mal, score) do
            :ok -> {:ok, score * 1.0}
            other -> {:error, other}
          end

        :tmdb ->
          if title.type == "movie",
            do: Laev.Tmdb.rate_movie(title.id, value),
            else: Laev.Tmdb.rate_tv(title.id, value)
      end
    end)
  end

  @doc "Take your rating back: `:ok` or `{:error, why}`."
  def clear_rating(uuid, title, entry \\ nil) do
    Roki.Laev.run(uuid, fn ->
      case rating_target(title, entry) do
        {:mal, mal} ->
          case Laev.MAL.rate(mal, 0) do
            :ok -> :ok
            other -> {:error, other}
          end

        :tmdb ->
          if title.type == "movie",
            do: Laev.Tmdb.clear_movie_rating(title.id),
            else: Laev.Tmdb.clear_tv_rating(title.id)
      end
    end)
  end

  @doc "Save for later (the watchlist's saved list), or take it off. `:added | :removed`."
  def toggle_saved(uuid, title) do
    result =
      Roki.Laev.run(uuid, fn ->
        Laev.Watchlist.toggle(%{
          type: title.type,
          id: title.id,
          title: title.title,
          year: title.year,
          # Laev keeps a full image address here (it draws the poster from it), not TMDB's path.
          poster: title.poster_path && "https://image.tmdb.org/t/p/w342" <> title.poster_path
        })
      end)

    library_changed(uuid)
    result
  end

  @doc "Take a title off the saved-for-later list."
  def unsave(uuid, type, id) do
    Roki.Laev.run(uuid, fn -> Laev.Watchlist.remove(type, id) end)
    library_changed(uuid)
  end

  @doc "Put on hold (on the shelf's On hold row), or take it off. `:held | :released`."
  def toggle_hold(uuid, title) do
    result = Roki.Laev.run(uuid, fn -> Laev.Holds.toggle(title.type, title.id) end)
    library_changed(uuid)
    result
  end

  @doc "Mark a film or one episode watched, or clear the mark. Sent to the user's other devices."
  def set_watched(uuid, title, season, episode, watched?) do
    ctx =
      Roki.Laev.run(uuid, fn ->
        ctx = build_ctx(title, season, episode)
        Laev.Position.set_watched(ctx, watched?)
        ctx
      end)

    if watched?, do: scrobble(uuid, [ctx])
    if title.type == "tv", do: follow_episodes(uuid, title, [ctx], watched?)

    library_changed(uuid)
  end

  @doc "Mark several episodes (`[{season, episode}]`) at once."
  def set_many_watched(uuid, title, pairs, watched?) do
    ctxs =
      Roki.Laev.run(uuid, fn ->
        for {s, e} <- pairs do
          ctx = build_ctx(title, s, e)
          Laev.Position.set_watched(ctx, watched?)
          ctx
        end
      end)

    if watched?, do: scrobble(uuid, ctxs)
    if title.type == "tv", do: follow_episodes(uuid, title, ctxs, watched?)

    library_changed(uuid)
  end

  @doc "Every episode that is out, across all seasons, marked or cleared. Slow for a long series."
  def set_series_watched(uuid, title, watched?) do
    pairs =
      for s <- aired_seasons(title),
          {:ok, eps} <- [episodes(title.id, s.number, uuid)],
          e <- eps,
          e.aired?,
          do: {s.number, e.number}

    set_many_watched(uuid, title, pairs, watched?)
    # The whole series, from the button under the poster: completed or not completed.
    set_completed(uuid, title, watched?)
    library_changed(uuid)
  end

  # Anime is kept on MyAnimeList: once an episode is watched, that entry's list count follows,
  # as the terminal app does it. Each entry gets the highest episode of it that was just done
  # (laev never lowers a count MyAnimeList already has) and finishing the last one completes it.
  # Nothing happens without a MyAnimeList login, and a failure never reaches the page.
  defp scrobble(uuid, ctxs) do
    Task.start(fn ->
      Roki.Laev.run(uuid, fn ->
        if Laev.MAL.authenticated?() do
          ctxs
          |> Enum.filter(&(is_integer(&1[:mal_id]) and is_integer(&1[:episode])))
          |> Enum.group_by(& &1.mal_id, & &1.episode)
          |> Enum.each(fn {mal, eps} ->
            Laev.MAL.set_progress(mal, Enum.max(eps), Laev.Anime.episodes(mal))
          end)
        end
      end)
    end)

    :ok
  rescue
    _ -> :ok
  end

  # Stats and the shelf's counts read the same marks; the other devices pick them up on a sync.
  defp library_changed(uuid) do
    Roki.Stats.forget(uuid)
    Task.start(fn -> Roki.Laev.run(uuid, &Laev.Sync.live_push/0) end)
    :ok
  end

  @doc "Episodes of one season: `{:ok, [%{number, name, overview, still, air_date, minutes, aired?}]}`."
  def episodes(tv_id, season, uuid \\ nil) when is_integer(tv_id) and is_integer(season) do
    TTLCache.fetch({:episodes, tv_id, season}, @episodes_ttl, fn ->
      Roki.Laev.public(uuid, fn ->
        with {:ok, %{"episodes" => eps}} <- Tmdb.season(tv_id, season) do
          today = Date.to_iso8601(Date.utc_today())

          {:ok,
           for e <- eps do
             %{
               number: e["episode_number"],
               name: e["name"],
               overview: blank(e["overview"]),
               still: Tmdb.poster_url(e["still_path"], "w300"),
               air_date: blank(e["air_date"]),
               minutes: e["runtime"],
               aired?: is_binary(e["air_date"]) and e["air_date"] != "" and e["air_date"] <= today
             }
           end}
        end
      end)
    end)
  end

  # ── what is being played ───────────────────────────────────────────

  @doc """
  The play context laev keys everything by (positions, resume, stats): film `type: "movie"`,
  episode `type: "tv"` with `season`/`episode`. An anime season carries its MyAnimeList id,
  because laev records anime under `mal-<id>-e<n>` — which is what keeps its watched marks
  and stats lined up with the terminal app.
  """
  def ctx(uuid, title, season \\ nil, episode \\ nil),
    do: Roki.Laev.run(uuid, fn -> build_ctx(title, season, episode) end)

  # Needs a laev scope: the season → MyAnimeList mapping is read from the user's files.
  defp build_ctx(title, season, episode) do
    # An anime episode is keyed by its MAL entry and the number inside that entry (laev's
    # `mal-<id>-e<n>`); `tmdb_episode` keeps TMDB's own number for the page.
    {mal, local} =
      case (title.anime? and title.type == "tv") &&
             Laev.Anime.Parts.locate(title.id, season, episode) do
        {mal, local} -> {mal, local}
        _ -> {nil, episode}
      end

    %{
      type: title.type,
      tmdb_id: title.id,
      season: season,
      episode: local,
      tmdb_episode: episode,
      title: title.title,
      poster_path: title.poster_path,
      year: title.year,
      anime: title.anime? and not is_nil(mal),
      search_title: mal && Laev.Anime.title(mal),
      mal_id: mal
    }
  end

  # ── 2. sources ─────────────────────────────────────────────────────

  @doc """
  `{:ok, %{query:, sources:}}` — releases for a film or an episode, ranked best first.
  Shared and cached ten minutes: nothing in it is about the user.
  """
  def sources(title, season, episode, uuid \\ nil, fresh? \\ false) do
    # Retry: the shared ten-minute list would just hand back what was already seen.
    if fresh?, do: TTLCache.delete({:sources, title.type, title.id, season, episode})

    TTLCache.fetch({:sources, title.type, title.id, season, episode}, @sources_ttl, fn ->
      isolated(fn -> Roki.Laev.public(uuid, fn -> search_sources(title, season, episode) end) end)
    end)
  end

  # The search asks several sites at once, and one of them being slow or dropping the connection
  # kills the request it was made in — which, run in the page's own process, took the page's
  # search down with it ("no sources") for what is only a flaky upstream. So it runs on its own,
  # may be asked again once, and a failure is an answer (`:search_failed`), never remembered.
  defp isolated(fun, attempts \\ 2) do
    task = Task.Supervisor.async_nolink(Roki.TaskSupervisor, fun)

    case Task.yield(task, 45_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ when attempts > 1 -> isolated(fun, attempts - 1)
      _ -> {:error, :search_failed}
    end
  end

  defp search_sources(%{type: "movie"} = t, _season, _episode) do
    [primary | alternates] = t.search.search
    q = join([Sources.query_title(primary), t.year])
    torrentio = t.imdb_id && {:movie, t.imdb_id}

    with {:ok, found} <- search(q, torrentio) do
      extra = Enum.flat_map(alternates, &extra_sources(join([Sources.query_title(&1), t.year])))
      {:ok, %{query: q, sources: finish(found ++ extra, t, :movie)}}
    end
  end

  # An anime season: its releases are fansub groups numbering by the anime's own episode
  # count, found by title and by Kitsu / AniDB id, never by "S02E05".
  defp search_sources(%{type: "tv", anime?: true} = t, season, episode) do
    located = season && Laev.Anime.Parts.locate(t.id, season, episode)

    if located do
      {mal, local} = located
      name = Laev.Anime.title(mal) || t.title

      {:ok, found, _scope} =
        Sources.anime_episode_search(name, local,
          anidb_id: Laev.AnimeMap.anidb(mal),
          kitsu_id: Laev.AnimeMap.kitsu_id(mal),
          search_title: name
        )

      {:ok, %{query: name, sources: Sources.rank(Enum.uniq_by(found, & &1.hash))}}
    else
      search_sources(%{t | anime?: false}, season, episode)
    end
  end

  defp search_sources(%{type: "tv"} = t, season, episode) do
    [primary | alternates] = t.search.search
    q = Sources.episode_query(Sources.query_title(primary), season, episode)
    torrentio = t.imdb_id && {:series, t.imdb_id, season, episode}

    with {:ok, found} <- search(q, torrentio) do
      extra =
        Enum.flat_map(
          alternates,
          &extra_sources(Sources.episode_query(Sources.query_title(&1), season, episode))
        )

      {:ok, %{query: q, sources: finish(found ++ extra, t, :tv)}}
    end
  end

  defp search(query, torrentio) do
    opts = if torrentio, do: [backend: :apibay, torrentio: torrentio], else: [backend: :apibay]

    # A site that has not answered after six seconds is left out rather than waited for.
    case Sources.search(query, [backend_timeout: 6_000] ++ opts) do
      {:ok, []} -> {:error, :no_sources}
      {:ok, sources} -> {:ok, sources}
      {:ok, sources, _late} -> {:ok, sources}
      {:error, reason} -> {:error, reason}
    end
  end

  # A second spelling of the title: finding nothing is normal, not a failure.
  defp extra_sources(query) do
    case Sources.search(query, backend: :apibay, backend_timeout: 6_000) do
      {:ok, sources} -> sources
      {:ok, sources, _late} -> sources
      _ -> []
    end
  end

  # Torrentio answers by IMDb id, so what it returns is the right title whatever the uploader
  # called it; everything from a text search has to prove it names this title.
  defp finish(sources, t, kind) do
    sources
    |> Enum.uniq_by(& &1.hash)
    |> Enum.filter(fn
      %{provider: "Torrentio" <> _} -> true
      s -> Sources.release_ok?(s.name, t.search.accept, t.year, kind)
    end)
    |> Sources.rank()
  end

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  @doc """
  Torrents already in the user's debrid account come first — instant, and certain to play.
  Run in the user's scope; a failure (no Real-Debrid, an error) just means no library.
  """
  def with_library(uuid, query, sources) do
    Roki.Laev.run(uuid, fn ->
      library =
        if Laev.RD.configured?() do
          query |> Laev.RD.library() |> Enum.map(&Sources.account_source/1)
        else
          []
        end

      (library ++ sources) |> Enum.uniq_by(& &1.hash) |> Sources.rank()
    end)
  rescue
    _ -> sources
  end

  @doc "One round of releases to probe, with a share of every resolution tier, and the rest."
  def probe_page(sources, size \\ @probe_page), do: Sources.probe_page(sources, size)

  @doc "Order probed `{source, stream}` pairs best first (laev's ranking: cached, resolution, size)."
  def rank_playable(pairs), do: Sources.rank_playable(pairs)

  @doc """
  Read each probed release's real audio and subtitle languages from the container (one
  concurrent round trip), let those replace the release-name guess the ranking uses — so a
  release you can watch with your subtitles is not sunk as "wrong language" — and rank.
  Run in the user's scope.
  """
  def attach_and_rank(uuid, playable, opts \\ []) do
    Roki.Laev.run(uuid, fn ->
      playable
      |> attach_tracks(opts)
      |> Enum.map(fn {source, stream} -> {with_track_langs(source, stream), stream} end)
      |> rank_playable()
    end)
  end

  # Reading each file's audio and subtitle tracks from the debrid account costs about two seconds
  # a round, and only decides anything when the language wanted is not English (the names, and
  # the search results' own language tags, already rule out a wrong-language release for English).
  # So when the caller is in a hurry and English is what is wanted, it is left out.
  defp attach_tracks(playable, opts) do
    in_a_hurry? = Keyword.get(opts, :fast, false)
    english? = Laev.Config.lang() == "en" and Laev.Config.subs_lang() in [nil, "en"]

    # A study session needs the real audio of every release, whatever the language.
    if in_a_hurry? and english? and not Roki.Study.active?(),
      do: playable,
      else: Laev.Providers.attach_tracks(playable)
  end

  defp with_track_langs(source, %{tracks: %{audio: audio, subs: subs}}) do
    source = Map.put(source, :subs, Laev.Tracks.rankable(subs))

    case Laev.Tracks.rankable(audio) do
      [] -> source
      langs -> Map.put(source, :langs, langs)
    end
  end

  defp with_track_langs(source, _stream), do: source

  # ── the user's ceiling and the automatic pick ──────────────────────

  @doc """
  The highest resolution to start by itself for this title on this device: what the user last
  picked for it by hand, else the setting for the player in use — laev's ceiling for an
  external player, the site's own browser cap for the page (default 1080p; a browser cannot
  decode HEVC, so more is a heavy re-encode, and the cap is never above 1080p). The two are
  independent settings. `nil` is no ceiling. Run in the user's scope.
  """
  def ceiling(uuid, ctx, mode, web) do
    limit = web["browser_max_resolution"] || @transcode_cap

    Roki.Laev.run(uuid, fn ->
      pref =
        case Laev.Resume.get(ctx.type, ctx.tmdb_id) do
          %{"pref_resolution" => r} when is_binary(r) -> r
          _ -> nil
        end

      case mode do
        :external -> pref || Laev.Config.max_resolution()
        :browser -> cap_to(pref || limit, limit)
      end
    end)
  end

  @doc "The lower of a ceiling and a limit (`nil` is no ceiling)."
  def cap_to(nil, limit), do: limit
  def cap_to(cap, limit), do: if(Sources.resolution_at_most?(limit, cap), do: limit, else: cap)

  @doc """
  What plays when nobody is asked — laev's own rule: the best release not above the ceiling,
  never a cam rip. `{:play, {source, stream}}` or `{:ask, why}`.
  """
  def auto_choice(playable, cap) do
    # A browser cannot decode HEVC/AV1, so those are re-encoded on this server by software:
    # a 4K one takes every core and ~7 GB. h264 is copied into HLS for free. So the pick is the
    # best h264 (or unlabelled) release first, and only without one a re-encode — at most 1080p.
    cheap = Enum.reject(playable, &heavy?/1)

    with :none <- pick(cheap, cap),
         :none <- pick(playable, at_most_cap(cap)) do
      case Laev.CLI.auto_choice(playable, cap) do
        {:play, pick, _note} -> {:play, pick}
        {:ask, why} -> {:ask, why}
      end
    end
  end

  defp pick([], _cap), do: :none

  defp pick(pairs, cap) do
    case Laev.CLI.auto_choice(pairs, cap) do
      {:play, pick, _note} -> {:play, pick}
      {:ask, _why} -> :none
    end
  end

  # The most we will re-encode, or the user's own ceiling when that is lower.
  defp at_most_cap(cap),
    do: if(Sources.resolution_at_most?(@transcode_cap, cap), do: @transcode_cap, else: cap)

  @doc """
  Which of these titles are not out yet: `%{{type, id} => ~D[2026-12-18]}`. Only titles dated this
  year or later are looked up (the date is in the title details, which are cached for twelve
  hours and shared with the title page and the hover card), a few at a time. A title whose
  date is unknown is left out rather than flagged.
  """
  def upcoming(uuid, items, today \\ Date.utc_today()) do
    year = Integer.to_string(today.year)

    items
    |> Enum.filter(&(is_binary(&1[:year]) and &1.year >= year and &1[:type] in ["movie", "tv"]))
    |> Task.async_stream(&{&1, title(&1.type, &1.id, uuid)},
      max_concurrency: 4,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {item, {:ok, %{date: date}}}}, acc when is_binary(date) ->
        with {:ok, d} <- Date.from_iso8601(date),
             :gt <- Date.compare(d, today) do
          Map.put(acc, {item.type, item.id}, d)
        else
          _ -> acc
        end

      _other, acc ->
        acc
    end)
  end

  @doc "Whether playing this release means re-encoding it here (its video is not h264)."
  defdelegate heavy?(source), to: Laev.Playback

  @doc """
  What plays when the release goes to the user's own player (VLC, mpv): nothing is decoded
  here, so laev's plain rule applies — the best release up to the ceiling, 4K and HEVC included.
  """
  def auto_choice_external(playable, cap), do: pick_or_ask(Laev.CLI.auto_choice(playable, cap))

  defp pick_or_ask({:play, pick, _note}), do: {:play, pick}
  defp pick_or_ask({:ask, why}), do: {:ask, why}

  @doc """
  Hand a probed release to an external player: writes the history entry (so it shows under
  Continue) and returns the direct link. Nothing is remuxed and no ffmpeg runs.
  """
  def external(uuid, ctx, source, stream) do
    Roki.Laev.run(uuid, fn ->
      save_resume(ctx, source)

      %{
        url: stream.url,
        filename: stream.filename,
        name: source.name,
        resolution: source.resolution,
        resume_at: Laev.Position.saved_position(ctx) || 0
      }
    end)
    |> tap(fn _ -> Roki.Activity.record(uuid, ctx, "started") end)
  end

  @doc "Mark this episode or film watched (an external player cannot report progress)."
  def mark_watched(uuid, ctx) do
    Roki.Laev.run(uuid, fn ->
      Laev.Position.set_watched(ctx, true)
      Laev.Sync.live_push()
    end)
    |> tap(fn _ -> Roki.Activity.record(uuid, ctx) end)
  end

  @doc """
  Whether the sources page starts the best source by itself (with a pop-up that can be
  cancelled): on unless the user set laev's auto-pick to off. Laev's own default asks each time,
  which in a browser would mean a page that never moves.
  """
  def auto_start?(uuid) do
    Roki.Laev.run(uuid, fn ->
      setting =
        Laev.Settings.get("LAEV_AUTO_SOURCE") |> to_string() |> String.downcase() |> String.trim()

      setting not in ["off", "false", "no", "0"]
    end)
  end

  @doc "Whether the user's settings want the best source played without asking."
  def auto_source?(uuid), do: Roki.Laev.run(uuid, &Laev.Config.auto_source?/0)

  @doc "The user's debrid subscription: `:ok` or `{:expired, detail}`. Checked once a day by laev."
  def subscription(uuid) do
    Roki.Laev.run(uuid, fn ->
      cond do
        not Laev.Providers.any_configured?() -> {:error, :no_provider}
        match?({:expired, _}, Laev.Account.ensure()) -> Laev.Account.ensure()
        true -> :ok
      end
    end)
  end

  # ── 4. playing it ──────────────────────────────────────────────────

  @doc """
  Start `stream` for this user and say where to play it from.

  `{:ok, player}` where `player` is `%{url:, hls?:, resume_at:, remux_id:, subtitles:}`:
  a release a browser can read is played directly; anything else is remuxed to HLS by laev
  (ffmpeg) and waited for until the first segments are on disk. Also writes the history entry,
  so the title shows up in the user's History and as the thing to continue.
  """
  def start(uuid, ctx, source, stream) do
    # A 4K re-encode on software never keeps up with playing, and takes every core trying.
    with true <- Roki.Keys.allow_play?(uuid) || {:error, :over_limit},
         :ok <- Laev.Playback.allowed?(source, max_height: 1080, max_encoders: @max_encoders) do
      Roki.Keys.record(uuid, :play)

      do_start(uuid, ctx, source, stream)
      |> tap(fn
        {:ok, _} -> Roki.Activity.record(uuid, ctx, "started")
        _ -> :ok
      end)
    end
  end

  defp do_start(uuid, ctx, source, stream) do
    Roki.Laev.run(uuid, fn ->
      with {:ok, src} <- Laev.Playback.browser_source(ctx, stream, title: ctx.title),
           true <- src.playable || {:error, src[:reason] || :not_playable},
           :ok <- ready(src) do
        save_resume(ctx, source)

        {:ok,
         %{
           url:
             if(src.kind == :remux, do: "/stream/#{src.remux_id}/playlist.m3u8", else: src.url),
           hls?: src.kind == :remux,
           resume_at: src.resume_at,
           remux_id: src[:remux_id],
           filename: src.filename,
           subtitles: embedded_subtitles(src)
         }}
      end
    end)
  end

  @doc """
  A subtitle in the user's own language from OpenSubtitles or Jimaku, when they have a key
  for one and the release did not carry it. Written next to the stream as WebVTT.
  `{:ok, %{lang:, label:, url:}}` or `:none` (no provider, nothing found — never an error:
  a subtitle problem must not get in the way of watching).
  """
  def external_subtitle(uuid, ctx, play_id, wanted \\ nil) do
    lang = wanted || Roki.Laev.run(uuid, fn -> Laev.Config.subs_lang() end)
    key = {ctx.type, ctx.tmdb_id, ctx[:season], ctx[:episode], lang}

    cond do
      not (is_binary(lang) and lang != "") ->
        :none

      match?({:ok, _}, Roki.SubCache.get_auto(key)) ->
        {:ok, found} = Roki.SubCache.get_auto(key)
        {:ok, place_auto(play_id, lang, found)}

      # Nothing found (or the service said no) a moment ago: do not ask again for hours.
      Roki.TTLCache.cached?({:os_none, key}) ->
        :none

      true ->
        case fetch_auto(uuid, ctx, lang) do
          {:ok, found} ->
            Roki.SubCache.put_auto(key, found)
            {:ok, place_auto(play_id, lang, found)}

          :none ->
            Roki.TTLCache.fetch({:os_none, key}, 6 * 3_600, fn -> {:ok, :none} end)
            :none
        end
    end
  rescue
    _ -> :none
  end

  defp fetch_auto(uuid, ctx, lang) do
    Roki.Laev.run(uuid, fn ->
      with true <- Laev.OpenSubtitles.configured?() or Laev.Jimaku.configured?(),
           {:ok, path, label} <-
             Laev.SubtitleFetch.fetch(Map.put(ctx, :search_title, ctx.search_title), lang),
           {:ok, body} <- File.read(path) do
        source = if String.starts_with?(label, "Jimaku"), do: "Jimaku", else: "OpenSubtitles"

        {:ok,
         %{
           label: "#{language(lang)} · #{source}",
           vtt: Laev.Subtitles.to_vtt(Path.basename(path), body)
         }}
      else
        _ -> :none
      end
    end)
  end

  defp place_auto(play_id, lang, %{label: label, vtt: vtt}) do
    dir = Laev.Remux.dir(play_id)
    File.mkdir_p!(dir)
    file = "ext-#{String.slice(lang, 0, 2)}.vtt"
    File.write!(Path.join(dir, file), vtt)
    %{lang: lang, label: label, url: "/stream/#{play_id}/#{file}"}
  end

  @doc """
  What the subtitle menu can offer from OpenSubtitles for this user: `:off` (no key), `:search`
  (a key, so the choices can be listed, but downloading needs the account login too) or `:full`.
  """
  def os_state(uuid) do
    Roki.Laev.run(uuid, &Laev.OpenSubtitles.state/0)
  end

  @doc "The OpenSubtitles files for what is playing, in one language: `{:ok, [%{id, release, downloads}]}`."
  def os_search(uuid, ctx, lang) do
    key = {:os_search, ctx.type, ctx.tmdb_id, ctx[:season], ctx[:episode], lang}

    case Roki.TTLCache.fetch(key, 3_600, fn -> os_search_live(uuid, ctx, lang) end) do
      {:ok, _} = ok -> ok
      other -> other
    end
  end

  defp os_search_live(uuid, ctx, lang) do
    Roki.Laev.run(uuid, fn ->
      case Laev.SubtitleFetch.candidates(ctx, lang, 25) do
        {:ok, found} ->
          {:ok,
           for(
             c <- found,
             c.provider == :opensubtitles,
             do: Map.take(c, [:id, :release, :downloads])
           )}

        {:error, _} ->
          {:error, "OpenSubtitles did not answer. Try again in a moment."}
      end
    end)
  rescue
    _ -> {:error, "OpenSubtitles did not answer. Try again in a moment."}
  end

  @doc "Download one OpenSubtitles file for the player: `{:ok, track}` or `{:error, why}`."
  def os_fetch(uuid, play_id, id, lang, release, media \\ nil)

  def os_fetch(uuid, play_id, id, lang, release, media) when is_integer(id) do
    result =
      case Roki.SubCache.get_file(id) do
        {:ok, vtt} -> {:ok, vtt}
        :miss -> os_download(uuid, id)
      end

    case result do
      {:ok, vtt} ->
        track = place_os(play_id, id, lang, release, vtt)
        if media, do: Roki.SubCache.add_pick(uuid, media, %{id: id, lang: lang, release: release})
        {:ok, track}

      error ->
        error
    end
  end

  def os_fetch(_uuid, _play_id, _id, _lang, _release, _media), do: {:error, "bad request"}

  # One download, ever, per file: the converted text is kept for good.
  defp os_download(uuid, id) do
    Roki.Laev.run(uuid, fn ->
      with true <-
             Laev.OpenSubtitles.can_download?() ||
               {:error, "Add your OpenSubtitles username and password in Settings to download."},
           _ <- Roki.Keys.record(uuid, :subtitle),
           {:ok, srt} <- Laev.OpenSubtitles.download_srt(id) do
        vtt = Laev.Subtitles.to_vtt("#{id}.srt", srt)
        Roki.SubCache.put_file(id, vtt)
        {:ok, vtt}
      else
        {:error, {:opensubtitles_download, 406, _}} ->
          {:error, "Your OpenSubtitles download quota for today is used up."}

        {:error, msg} when is_binary(msg) ->
          {:error, msg}

        _ ->
          {:error, "OpenSubtitles would not give that file. Try another."}
      end
    end)
  rescue
    _ -> {:error, "OpenSubtitles would not give that file. Try another."}
  end

  defp place_os(play_id, id, lang, release, vtt) do
    dir = Laev.Remux.dir(play_id)
    File.mkdir_p!(dir)
    file = "ext-#{String.slice(lang, 0, 3)}-os#{id}.vtt"
    File.write!(Path.join(dir, file), vtt)

    %{
      lang: lang,
      label: "#{language(lang)} · OpenSubtitles · #{String.slice(release || "", 0, 70)}",
      url: "/stream/#{play_id}/#{file}"
    }
  end

  @doc """
  The OpenSubtitles files this user picked for this title before, as tracks again — read from the
  disk cache, never from the service. A file whose copy is gone is left out rather than fetched.
  """
  def os_saved(uuid, media, play_id) do
    for %{id: id, lang: lang, release: release} <- Roki.SubCache.picks(uuid, media),
        {:ok, vtt} <- [Roki.SubCache.get_file(id)] do
      place_os(play_id, id, lang, release, vtt)
    end
  rescue
    _ -> []
  end

  @doc """
  The languages worth fetching from a provider for what is playing, beyond what the release
  carries: the user's own, and — for anime, when a Jimaku key is set — the original Japanese.
  """
  def external_langs(uuid, ctx, tracks) do
    Roki.Laev.run(uuid, fn ->
      have = MapSet.new(tracks, &short_code(&1.lang))
      prefer = short_code(Laev.Config.subs_lang())
      jimaku? = ctx.anime and Laev.Jimaku.configured?()

      ([prefer] ++ if(jimaku?, do: ["ja"], else: []))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(have, &1))
    end)
  end

  @doc """
  The Japanese subtitle files Jimaku has for this anime episode, as tracks: the one most likely to
  be timed like the release first. Jimaku holds several per episode — the broadcast, Netflix's and
  Amazon's cuts, fansub groups' — and they do not all start at the same second; laev's own fetch
  takes the first it finds, which is often a streaming cut that runs half a minute off a rip. So
  the plausible ones are all offered, each named by where it came from (the sync buttons cover
  the rest). `source_name` is the release being played: a file from the same group comes first.
  """
  def jimaku_tracks(uuid, ctx, play_id, source_name) do
    Roki.Laev.run(uuid, fn ->
      query = ctx[:search_title] || ctx.title

      with true <- Laev.Jimaku.configured?(),
           {:ok, [_ | _] = files} <- Laev.Jimaku.candidates(query, ctx[:episode], source_name, 5) do
        tracks =
          files
          |> Enum.with_index()
          |> Enum.flat_map(fn {file, i} -> jimaku_track(file, i, play_id) end)

        if tracks == [], do: :none, else: {:ok, tracks}
      else
        _ -> :none
      end
    end)
  rescue
    _ -> :none
  end

  defp jimaku_label(name) do
    cond do
      String.match?(name, ~r/^\[([^\]]+)\]/) ->
        hd(Regex.run(~r/^\[([^\]]+)\]/, name, capture: :all_but_first))

      String.contains?(String.downcase(name), "netflix") ->
        "Netflix"

      String.contains?(String.downcase(name), "amazon") ->
        "Amazon"

      String.contains?(String.downcase(name), "crunchyroll") ->
        "Crunchyroll"

      true ->
        "Jimaku"
    end
  end

  defp jimaku_track(%{name: name, url: url}, i, play_id) do
    with {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.get(url, receive_timeout: 15_000, retry: :transient, max_retries: 1),
         vtt when is_binary(vtt) <- Laev.Subtitles.to_vtt(name, body) do
      dir = Laev.Remux.dir(play_id)
      File.mkdir_p!(dir)
      file = if i == 0, do: "ext-ja.vtt", else: "ext-ja-#{i + 1}.vtt"
      File.write!(Path.join(dir, file), vtt)

      [
        %{
          lang: "ja",
          label: "Japanese · #{jimaku_label(name)}",
          url: "/stream/#{play_id}/#{file}"
        }
      ]
    else
      _ -> []
    end
  end

  @doc "The user's preferred subtitle language, as a two-letter code (laev's setting)."
  def preferred_subs(uuid), do: Roki.Laev.run(uuid, fn -> Laev.Config.subs_lang() end)

  @doc "Whether the user's setting wants the next episode to start by itself."
  def autoplay?(uuid), do: Roki.Laev.run(uuid, &Laev.Config.autoplay?/0)

  # A conversion that did not get going is stopped, not left to run its two hours.
  defp ready(%{kind: :remux, remux_id: id}), do: await_segments(id, 180_000)
  defp ready(_), do: :ok

  # Playing can begin once the first two segments (about eight seconds) are written: the converter
  # runs far ahead of playback, and laev's own wait is for four, polled every 0.3 s. A wait that
  # runs out stops the conversion, as laev's does.
  defp await_segments(id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_segments(id, deadline)
  end

  defp wait_segments(id, deadline) do
    cond do
      segments_ready?(id) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        Laev.Remux.stop(id)
        {:error, :timeout}

      true ->
        Process.sleep(150)
        wait_segments(id, deadline)
    end
  end

  defp segments_ready?(id) do
    dir = Laev.Remux.dir(id)
    # Several audio tracks: the video is in `s_0.m3u8`, under a master playlist.
    file = if File.exists?(Path.join(dir, "master.m3u8")), do: "s_0.m3u8", else: "index.m3u8"

    case File.read(Path.join(dir, file)) do
      {:ok, pl} -> pl =~ "#EXT-X-ENDLIST" or length(String.split(pl, ".ts")) >= 3
      _ -> false
    end
  end

  defp embedded_subtitles(%{kind: :remux, remux_id: id}) do
    # laev lists a track by its basename (`sub0`); ffmpeg writes, and the stream route serves,
    # `sub0.vtt` — without the extension every embedded track is a 400.
    for t <- Laev.Playback.subtitles(id), is_binary(t[:file]) do
      file = if String.ends_with?(t.file, ".vtt"), do: t.file, else: t.file <> ".vtt"
      %{lang: t.lang, label: language(t.lang), url: "/stream/#{id}/#{file}"}
    end
  end

  defp embedded_subtitles(_), do: []

  # The user's own history: where they are, and the release they chose.
  defp save_resume(ctx, source) do
    entry =
      (Laev.Resume.get(ctx.type, ctx.tmdb_id) || %{})
      |> Map.merge(%{
        "type" => ctx.type,
        "tmdb_id" => ctx.tmdb_id,
        "season" => ctx.season,
        "episode" => ctx.episode,
        "tmdb_episode" => ctx.tmdb_episode,
        "title" => ctx.title,
        "poster_path" => ctx.poster_path,
        "anime" => ctx.anime,
        "search_title" => ctx.search_title,
        "mal_id" => ctx.mal_id,
        "source" => %{"name" => source.name, "magnet" => source.magnet, "hash" => source.hash},
        "updated_at" => System.os_time(:second)
      })

    Laev.Resume.put(ctx.type, ctx.tmdb_id, entry)
  end

  @doc "Remember the resolution picked by hand for this title, so its next episode starts there too."
  def remember_resolution(uuid, ctx, %{resolution: r}) when is_binary(r) do
    Roki.Laev.run(uuid, fn ->
      entry = Laev.Resume.get(ctx.type, ctx.tmdb_id)
      if entry, do: Laev.Resume.put(ctx.type, ctx.tmdb_id, Map.put(entry, "pref_resolution", r))
      :ok
    end)
  end

  def remember_resolution(_uuid, _ctx, _source), do: :ok

  @doc """
  Record where the player has got to. The arithmetic — what was watched, what was skipped,
  when it counts as finished (85%) — is laev's, so it is exactly what the terminal app writes.
  `{:finished, true}` is returned the first time it crosses into watched.
  """
  def record_progress(uuid, ctx, position, duration, paused? \\ false) when is_number(position) do
    # Stopped: send the position to the user's other devices now (the terminal app picks it up
    # on its next sync), without making the player wait for the network.
    if paused?, do: Task.start(fn -> Roki.Laev.run(uuid, &Laev.Sync.live_push/0) end)

    Roki.Laev.run(uuid, fn ->
      before? = Laev.Position.finished?(ctx)
      Laev.Playback.progress(ctx, position, duration: duration, interval: 5)
      finished? = Laev.Position.finished?(ctx)
      if finished? and not before?, do: Laev.Sync.live_push()
      {:finished, finished? and not before?}
    end)
    |> tap(fn {:finished, new?} ->
      if new? do
        scrobble(uuid, [ctx])
        Roki.Activity.record(uuid, ctx)
      end
    end)
  end

  @doc "Where playback should resume, in seconds (0 = from the start)."
  def resume_at(uuid, ctx),
    do: Roki.Laev.run(uuid, fn -> Laev.Position.saved_position(ctx) || 0 end)

  @doc """
  What the season picker lists: one *section* per TMDB season — or, for anime where TMDB has
  merged several cours into one season, one per MyAnimeList entry, numbered the way MAL does.
  `%{key, season, from, count, total, mal, label, short}`: `season` is TMDB's; `from`/`count`
  say which of its episodes the section holds (episode `from + 1` is this section's number 1);
  `short` is the "S2" the buttons use.
  """
  def sections(uuid, title) do
    Roki.Laev.run(uuid, fn -> build_sections(title) end)
  end

  defp build_sections(title) do
    main = Enum.count(title.seasons, &(&1.number > 0))

    Enum.flat_map(title.seasons, fn s ->
      name = s.name || "Season #{s.number}"

      parts =
        if title.anime? and s.number > 0,
          do: Laev.Anime.Parts.parts(title.id, s.number, s.episodes),
          else: []

      case parts do
        [_, _ | _] ->
          last = length(parts)

          {out, _} =
            parts
            |> Enum.with_index(1)
            |> Enum.map_reduce(0, fn {{mal, count}, i}, from ->
              last? = i == last
              n = count || 0

              {%{
                 key: "#{s.number}.#{i}",
                 season: s.number,
                 from: from,
                 count: if(last?, do: nil, else: count),
                 total: if(last?, do: max((s.episodes || 0) - from, n), else: n),
                 mal: mal,
                 label: if(main == 1, do: "Season #{i}", else: "#{name} · Part #{i}"),
                 short: if(main == 1, do: "S#{i}", else: "S#{s.number}P#{i}")
               }, from + n}
            end)

          out

        _ ->
          [
            %{
              key: "#{s.number}",
              season: s.number,
              from: 0,
              count: nil,
              total: s.episodes || 0,
              mal: with([{mal, _}] <- parts, do: mal, else: (_ -> nil)),
              label: name,
              short: "S#{s.number}"
            }
          ]
      end
    end)
  end

  @doc """
  The episode after this one, `{season, episode, tag}` (TMDB's numbers, and the "S2E1" the pages
  call it): the next one that is out in the season, else the first one out of the next season;
  nil at the end (or when TMDB cannot say).
  """
  def next_episode(uuid, title, season, episode)
      when is_integer(season) and is_integer(episode) do
    pick = fn s ->
      with {:ok, eps} <- episodes(title.id, s, uuid), do: Enum.find(eps, & &1.aired?)
    end

    found =
      with {:ok, eps} <- episodes(title.id, season, uuid),
           %{number: n} <- Enum.find(eps, &(&1.number > episode and &1.aired?)) do
        {season, n}
      else
        _ ->
          title.seasons
          |> Enum.filter(&(&1.number > season))
          |> Enum.sort_by(& &1.number)
          |> Enum.find_value(fn s ->
            case pick.(s.number) do
              %{number: n} -> {s.number, n}
              _ -> nil
            end
          end)
      end

    with {s, e} <- found, do: {s, e, episode_tag(uuid, title, s, e)}
  end

  def next_episode(_uuid, _title, _season, _episode), do: nil

  @doc """
  The episode before this one, `{season, episode, tag}`: the last one before it in the season, else
  the last one of the season before (specials, season 0, are not walked into); nil at the start.
  """
  def previous_episode(uuid, title, season, episode)
      when is_integer(season) and is_integer(episode) do
    found =
      with {:ok, eps} <- episodes(title.id, season, uuid),
           %{number: n} <- eps |> Enum.filter(&(&1.number < episode)) |> List.last() do
        {season, n}
      else
        _ ->
          title.seasons
          |> Enum.filter(&(&1.number < season and &1.number > 0))
          |> Enum.sort_by(& &1.number, :desc)
          |> Enum.find_value(fn s ->
            with {:ok, eps} <- episodes(title.id, s.number, uuid),
                 %{number: n} <- List.last(eps) do
              {s.number, n}
            else
              _ -> nil
            end
          end)
      end

    with {s, e} <- found, do: {s, e, episode_tag(uuid, title, s, e)}
  end

  def previous_episode(_uuid, _title, _season, _episode), do: nil

  @doc """
  An episode as the pages call it — "S2E1" — in the numbering of the season picker, so an
  anime whose TMDB season was split reads like the anime list does. Cheap for anything that
  is not split.
  """
  def episode_tag(uuid, title, season, episode) when is_integer(season) and is_integer(episode) do
    with true <- title.anime?,
         [_ | _] = sections <- sections(uuid, title),
         {sec, local} <- locate_section(sections, season, episode) do
      "#{sec.short}E#{local}"
    else
      _ -> "S#{season}E#{episode}"
    end
  end

  def episode_tag(_uuid, _title, _season, _episode), do: nil

  @doc "The section holding a TMDB season's episode, and that episode's number inside it."
  def locate_section(sections, season, tmdb_episode) do
    sec =
      Enum.find(sections, fn x ->
        x.season == season and tmdb_episode > x.from and
          (x.count == nil or tmdb_episode <= x.from + x.count)
      end) || Enum.find(sections, &(&1.season == season))

    if sec, do: {sec, max(tmdb_episode - sec.from, 1)}, else: nil
  end

  @doc """
  Where the big Play button goes and what it says: `%{season, episode, continue?, label}` —
  `season`/`episode` are TMDB's (what the sources page takes), `label` is the section's own
  numbering ("S2.E1").
  """
  def play_info(sections, resume) do
    first = Enum.find(sections, &(&1.season > 0)) || List.first(sections)

    with %{"season" => s, "episode" => e} = r when is_integer(s) and is_integer(e) <- resume,
         tmdb = r["tmdb_episode"] || e,
         {sec, local} <- locate_section(sections, s, tmdb) do
      %{
        season: s,
        episode: tmdb,
        continue?: true,
        verb: "Continue",
        label: "#{sec.short}.E#{local}"
      }
    else
      _ ->
        if first,
          do: %{
            season: first.season,
            episode: first.from + 1,
            continue?: false,
            verb: "Start",
            label: "#{first.short}.E1"
          },
          else: %{season: 1, episode: 1, continue?: false, verb: "Start", label: "S1.E1"}
    end
  end

  @doc """
  What Play should offer for a series, from what is actually watched rather than only from the
  last thing played: an episode left half-way is "Continue"; otherwise "Next" is the first
  unwatched episode after the last one you finished (the next season's first, when a season is
  done); with nothing watched it is "Start", and with everything watched "Watch again".
  Anything skipped earlier is only offered when nothing lies ahead.
  """
  def play_for(uuid, title, sections, resume) do
    base = play_info(sections, resume)

    if sections == [] do
      base
    else
      counts = section_counts(uuid, title, sections)
      started? = Enum.any?(counts, fn {_key, n} -> n > 0 end)

      cond do
        base.continue? and not episode_done?(uuid, title, base.season, base.episode) ->
          base

        not started? and not base.continue? ->
          base

        true ->
          case next_unseen(uuid, title, sections, counts) do
            {sec, tmdb_ep} ->
              %{
                season: sec.season,
                episode: tmdb_ep,
                continue?: true,
                verb: "Next",
                label: "#{sec.short}.E#{tmdb_ep - sec.from}"
              }

            nil ->
              %{play_info(sections, nil) | verb: "Watch again"}
          end
      end
    end
  end

  defp episode_done?(uuid, title, season, episode),
    do: MapSet.member?(watched_episodes(uuid, title, season, [%{number: episode}]), episode)

  # The first unwatched, aired episode after the last section with anything watched in it (after
  # its furthest watched episode there); failing that, a gap further back.
  defp next_unseen(uuid, title, sections, counts) do
    real = Enum.filter(sections, &(&1.season > 0))

    last =
      real
      |> Enum.map(&(Map.get(counts, &1.key, 0) > 0))
      |> Enum.reverse()
      |> Enum.find_index(& &1)

    from_idx = if last, do: length(real) - 1 - last, else: 0
    {behind, ahead} = Enum.split(real, from_idx)

    unwatched_in(uuid, title, ahead, counts, true) ||
      unwatched_in(uuid, title, behind, counts, false)
  end

  defp unwatched_in(uuid, title, sections, counts, after_furthest?) do
    sections
    |> Enum.with_index()
    |> Enum.find_value(fn {sec, i} ->
      done? = sec.total > 0 and Map.get(counts, sec.key, 0) >= sec.total

      with false <- done?,
           {:ok, all} <- episodes(title.id, sec.season, uuid) do
        eps =
          for e <- all,
              e.number > sec.from and (sec.count == nil or e.number <= sec.from + sec.count),
              do: e

        watched = watched_episodes(uuid, title, sec.season, eps)

        floor =
          if after_furthest? and i == 0, do: Enum.max(MapSet.to_list(watched) ++ [0]), else: 0

        case Enum.find(
               eps,
               &(&1.aired? and &1.number > floor and not MapSet.member?(watched, &1.number))
             ) do
          nil -> nil
          e -> {sec, e.number}
        end
      else
        _ -> nil
      end
    end)
  end

  @doc "How many episodes of each section are marked watched: `%{key => count}`."
  def section_counts(uuid, title, sections) do
    Roki.Laev.run(uuid, fn ->
      if title.anime? do
        marks = Laev.Position.anime_marks()
        by_season = Map.get(Laev.Position.episode_marks(), {"tv", title.id}, %{})

        # A season with no MyAnimeList entry is marked per episode on TMDB's side.
        Map.new(sections, fn sec ->
          {sec.key,
           if(sec.mal, do: Map.get(marks, sec.mal, 0), else: Map.get(by_season, sec.season, 0))}
        end)
      else
        by_season = Map.get(Laev.Position.episode_marks(), {"tv", title.id}, %{})
        Map.new(sections, &{&1.key, Map.get(by_season, &1.season, 0)})
      end
    end)
  end

  @doc "Which of these episodes the user has watched: a `MapSet` of episode numbers."
  def watched_episodes(uuid, title, season, episodes) do
    Roki.Laev.run(uuid, fn ->
      for e <- episodes,
          Laev.Position.finished?(build_ctx(title, season, e.number)),
          into: MapSet.new(),
          do: e.number
    end)
  end

  # ── small things the page needs ────────────────────────────────────

  @languages %{
    "en" => "English",
    "ja" => "Japanese",
    "fr" => "French",
    "es" => "Spanish",
    "de" => "German",
    "it" => "Italian",
    "pt" => "Portuguese",
    "ru" => "Russian",
    "ko" => "Korean",
    "zh" => "Chinese",
    "ar" => "Arabic",
    "nl" => "Dutch",
    "pl" => "Polish",
    "tr" => "Turkish",
    "sv" => "Swedish",
    "eng" => "English",
    "jpn" => "Japanese",
    "fre" => "French",
    "fra" => "French",
    "spa" => "Spanish",
    "ger" => "German",
    "deu" => "German",
    "ita" => "Italian",
    "por" => "Portuguese",
    "rus" => "Russian",
    "kor" => "Korean",
    "chi" => "Chinese",
    "zho" => "Chinese"
  }

  @doc "A language code (`fr`, `fre`, `jpn`) as a name; unknown codes are shown upper-cased."
  def language(code) when is_binary(code) and code != "",
    do: Map.get(@languages, String.downcase(code), String.upcase(code))

  def language(_), do: "Unknown"

  @doc "The two-letter code for a language code (`fre` → `fr`), for matching the user's setting."
  def short_code(code) when is_binary(code) do
    c = String.downcase(code)

    case c do
      "eng" -> "en"
      "jpn" -> "ja"
      "fre" -> "fr"
      "fra" -> "fr"
      "spa" -> "es"
      "ger" -> "de"
      "deu" -> "de"
      "ita" -> "it"
      "por" -> "pt"
      "rus" -> "ru"
      "kor" -> "ko"
      "chi" -> "zh"
      "zho" -> "zh"
      other -> String.slice(other, 0, 2)
    end
  end

  def short_code(_), do: ""

  @doc "A human reason a source could not be used, from laev's probe errors."
  def why(:known_blocked), do: "taken down"
  def why(:infringing), do: "taken down"
  def why({:rd, 451, _}), do: "taken down"
  def why({:error, reason}), do: why(reason)
  def why(:no_provider), do: "no debrid account connected"
  def why(:no_sources), do: "no releases found"
  def why(:timeout), do: "timed out"
  def why(:another_episode), do: "that release is another episode"
  def why(:no_file_for_episode), do: "that pack has no file for this episode"
  def why({:expired, detail}), do: "your debrid subscription isn't active (#{detail})"
  def why(other) when is_binary(other), do: other
  def why(other), do: "unavailable (#{inspect(other, limit: 3, printable_limit: 60)})"
end
