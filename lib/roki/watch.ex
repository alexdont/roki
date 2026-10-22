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
    TTLCache.fetch({:title, type, id}, @details_ttl, fn ->
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
    mal =
      if title.anime? and title.type == "tv" and season,
        do: Laev.AnimeMap.mal_id("tv", title.id, season)

    %{
      type: title.type,
      tmdb_id: title.id,
      season: season,
      episode: episode,
      title: title.title,
      poster_path: title.poster_path,
      year: title.year,
      anime: title.anime? and not is_nil(mal),
      search_title: nil,
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
      Roki.Laev.public(uuid, fn -> search_sources(title, season, episode) end)
    end)
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
    mal = season && Laev.AnimeMap.mal_id("tv", t.id, season)

    if mal do
      name = Laev.Anime.title(mal) || t.title

      {:ok, found, _scope} =
        Sources.anime_episode_search(name, episode,
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

    case Sources.search(query, opts) do
      {:ok, []} -> {:error, :no_sources}
      {:ok, sources} -> {:ok, sources}
      {:error, reason} -> {:error, reason}
    end
  end

  # A second spelling of the title: finding nothing is normal, not a failure.
  defp extra_sources(query) do
    case Sources.search(query, backend: :apibay) do
      {:ok, sources} -> sources
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
  def probe_page(sources), do: Sources.probe_page(sources, @probe_page)

  @doc "Order probed `{source, stream}` pairs best first (laev's ranking: cached, resolution, size)."
  def rank_playable(pairs), do: Sources.rank_playable(pairs)

  @doc """
  Read each probed release's real audio and subtitle languages from the container (one
  concurrent round trip), let those replace the release-name guess the ranking uses — so a
  release you can watch with your subtitles is not sunk as "wrong language" — and rank.
  Run in the user's scope.
  """
  def attach_and_rank(uuid, playable) do
    Roki.Laev.run(uuid, fn ->
      playable
      |> Laev.Providers.attach_tracks()
      |> Enum.map(fn {source, stream} -> {with_track_langs(source, stream), stream} end)
      |> rank_playable()
    end)
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
  def heavy?({source, _stream}), do: heavy?(source)
  def heavy?(%{codec: codec}) when codec in ["h265", "av1"], do: true
  def heavy?(_), do: false

  # ffmpeg processes alive right now (a copy is light; a re-encode is not).
  defp encoders_running do
    case System.cmd("pgrep", ["-c", "-x", "ffmpeg"], stderr_to_stdout: true) do
      {n, _} -> n |> String.trim() |> String.to_integer()
    end
  rescue
    _ -> 0
  end

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
  end

  @doc "Mark this episode or film watched (an external player cannot report progress)."
  def mark_watched(uuid, ctx) do
    Roki.Laev.run(uuid, fn ->
      Laev.Position.set_watched(ctx, true)
      Laev.Sync.live_push()
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
    if heavy?(source) and encoders_running() >= @max_encoders do
      {:error, :busy}
    else
      do_start(uuid, ctx, source, stream)
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
  def external_subtitle(uuid, ctx, play_id) do
    Roki.Laev.run(uuid, fn ->
      lang = Laev.Config.subs_lang()

      with true <- is_binary(lang) and lang != "",
           true <- Laev.OpenSubtitles.configured?() or Laev.Jimaku.configured?(),
           {:ok, path, label} <-
             Laev.SubtitleFetch.fetch(Map.put(ctx, :search_title, ctx.search_title), lang),
           {:ok, body} <- File.read(path) do
        dir = Laev.Remux.dir(play_id)
        File.mkdir_p!(dir)
        file = "ext-#{String.slice(lang, 0, 2)}.vtt"
        File.write!(Path.join(dir, file), Roki.Subtitles.to_vtt(Path.basename(path), body))
        {:ok, %{lang: lang, label: label, url: "/stream/#{play_id}/#{file}"}}
      else
        _ -> :none
      end
    end)
  rescue
    _ -> :none
  end

  @doc "The user's preferred subtitle language, as a two-letter code (laev's setting)."
  def preferred_subs(uuid), do: Roki.Laev.run(uuid, fn -> Laev.Config.subs_lang() end)

  @doc "Whether the user's setting wants the next episode to start by itself."
  def autoplay?(uuid), do: Roki.Laev.run(uuid, &Laev.Config.autoplay?/0)

  defp ready(%{kind: :remux, remux_id: id}), do: Laev.Playback.ready(id, :fast, 180_000)
  defp ready(_), do: :ok

  defp embedded_subtitles(%{kind: :remux, remux_id: id}) do
    for t <- Laev.Playback.subtitles(id), is_binary(t[:file]) do
      %{lang: t.lang, label: language(t.lang), url: "/stream/#{id}/#{t.file}"}
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
  end

  @doc "Where playback should resume, in seconds (0 = from the start)."
  def resume_at(uuid, ctx),
    do: Roki.Laev.run(uuid, fn -> Laev.Position.saved_position(ctx) || 0 end)

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
  def why({:expired, detail}), do: "your debrid subscription isn't active (#{detail})"
  def why(other) when is_binary(other), do: other
  def why(other), do: "unavailable (#{inspect(other, limit: 3, printable_limit: 60)})"
end
