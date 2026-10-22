defmodule RokiWeb.TitleLive do
  @moduledoc """
  `/title/:type/:id` — a film or a show, and the way to watch it.

  Every poster on the site leads here. The page shows what TMDB knows; for a signed-in user
  who has connected laev it also plays: pressing Play (or an episode) searches releases,
  asks their Real-Debrid / TorBox which actually play, picks the best the way laev's terminal
  app does (their resolution ceiling, never a cam rip) — or lists them to choose from — and
  plays the result in the study player, subtitles beside it. Where they are is written back
  through laev, so History, the shelf and stats follow, and it syncs to the terminal app.

  The flow itself is `Roki.Watch`; this page is its state and its screen.
  """
  use RokiWeb, :live_view

  import RokiWeb.StudyComponents

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Watch
  alias Roki.Watch.SourceCache

  # ── mount & params ─────────────────────────────────────────────────

  @impl true
  def mount(%{"type" => type, "id" => id}, _session, socket) do
    case {type in ~w(movie tv), Integer.parse(id)} do
      {true, {n, ""}} -> {:ok, init(socket, type, n)}
      _ -> {:ok, push_navigate(socket, to: ~p"/home")}
    end
  end

  defp init(socket, type, id) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    uuid = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)

    socket =
      assign(socket,
        type: type,
        id: id,
        uuid: uuid,
        linked?: uuid != nil and Roki.Laev.connected?(uuid),
        mode: mode_param(socket),
        platform: platform_param(socket),
        external: nil,
        cache_info: nil,
        cache_key: nil,
        cached: MapSet.new(),
        lib: %{saved?: false, held?: false, watched?: false, all_watched?: false},
        lib_busy: false,
        rating: %{state: :loading, value: nil},
        rating_error: nil,
        page_title: "Watch",
        title: nil,
        title_error: nil,
        resume: nil,
        req_season: nil,
        req_episode: nil,
        season: nil,
        episode: nil,
        episodes: nil,
        watched: MapSet.new(),
        phase: :idle,
        probe: nil,
        ctx: nil,
        playable: [],
        rest: [],
        current: nil,
        player: nil,
        token: 0,
        up_next: nil
      )

    if connected?(socket),
      do: start_async(socket, :title, fn -> load_title(type, id, uuid) end),
      else: socket
  end

  # How this device plays: the page tells us (`player` in the socket params, from the browser's
  # own storage; a phone defaults to its own player). `platform` picks which link to lead with.
  defp mode_param(socket),
    do: if(connect_param(socket, "player") == "browser", do: :browser, else: :external)

  defp platform_param(socket) do
    case connect_param(socket, "platform") do
      p when p in ["ios", "android"] -> String.to_existing_atom(p)
      _ -> :desktop
    end
  end

  defp connect_param(socket, key) do
    if connected?(socket), do: (get_connect_params(socket) || %{})[key]
  end

  defp cached_keys(uuid) do
    hours = SourceCache.hours(Roki.Laev.web_settings(uuid))
    SourceCache.keys(uuid, hours)
  end

  defp rating_state({:ok, value}), do: %{state: :ok, value: value}
  defp rating_state(:no_account), do: %{state: :no_account, value: nil}
  defp rating_state(_), do: %{state: :loading, value: nil}

  defp load_title(type, id, uuid) do
    with {:ok, title} <- Watch.title(type, id, uuid) do
      linked? = uuid && Roki.Laev.connected?(uuid)
      resume = if linked?, do: Roki.Laev.run(uuid, fn -> Laev.Resume.get(type, id) end)
      cached = if linked?, do: cached_keys(uuid), else: MapSet.new()
      lib = if linked?, do: Watch.library(uuid, title)
      rating = if linked?, do: Watch.my_rating(uuid, title)

      {:ok, title, resume, cached, lib, rating}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      assign(socket,
        req_season: to_int(params["s"]),
        req_episode: to_int(params["e"])
      )

    {:noreply, select(socket)}
  end

  # Settle which season (and episode) the page is on, and load that season's episodes.
  defp select(%{assigns: %{title: nil}} = socket), do: socket
  defp select(%{assigns: %{type: "movie"}} = socket), do: socket

  defp select(%{assigns: %{title: title, resume: resume, req_season: req}} = socket) do
    numbers = Enum.map(title.seasons, & &1.number)
    wanted = req || (resume && resume["season"]) || List.first(numbers)
    season = if wanted in numbers, do: wanted, else: List.first(numbers)

    socket = assign(socket, episode: socket.assigns.req_episode)

    if season != socket.assigns.season or socket.assigns.episodes == nil do
      load_episodes(assign(socket, season: season, episodes: nil), season)
    else
      socket
    end
  end

  defp load_episodes(socket, nil), do: socket

  defp load_episodes(socket, season) do
    %{id: id, uuid: uuid, title: title, linked?: linked?} = socket.assigns

    start_async(socket, :episodes, fn ->
      with {:ok, eps} <- Watch.episodes(id, season, uuid) do
        watched =
          if linked?, do: Watch.watched_episodes(uuid, title, season, eps), else: MapSet.new()

        {:ok, season, eps, watched}
      end
    end)
  end

  defp to_int(nil), do: nil

  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("play", params, socket) do
    {season, episode} = target(socket, params)
    {:noreply, socket |> patch(season, episode) |> begin(season, episode, false)}
  end

  def handle_event("select_season", %{"season" => s}, socket),
    do:
      {:noreply,
       push_patch(socket, to: ~p"/title/#{socket.assigns.type}/#{socket.assigns.id}?#{[s: s]}")}

  # The user chose from the list: that is a stronger statement than a setting, so the
  # next episode of this show starts at the same resolution (laev's rule).
  def handle_event("choose", %{"idx" => idx} = params, socket) do
    case Enum.at(socket.assigns.playable, to_int(idx) || -1) do
      nil ->
        {:noreply, socket}

      {source, _stream} = pair ->
        Watch.remember_resolution(socket.assigns.uuid, socket.assigns.ctx, source)

        if socket.assigns.mode == :external or params["via"] == "external",
          do: {:noreply, hand_over(socket, pair)},
          else: {:noreply, play_pair(socket, pair)}
    end
  end

  # Which player this device uses; remembered in the browser, not on the server.
  # Look for sources again, ignoring the cached ones (they may be stale or new ones may exist).
  def handle_event("retry", _params, socket) do
    %{season: season, episode: episode} = socket.assigns
    {:noreply, begin(socket, season, episode, true)}
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ["browser", "external"] do
    {:noreply,
     socket
     |> assign(mode: String.to_existing_atom(mode))
     |> push_event("roki:player", %{mode: mode})}
  end

  # ── marking and saving: what the terminal app does with a title ────

  # Films: one mark. Series: every episode that is out (many lookups, so it runs apart).
  def handle_event("toggle_watched", _params, %{assigns: %{type: "movie"}} = socket) do
    %{uuid: uuid, title: title, lib: lib} = socket.assigns
    new = not lib.watched?
    Watch.set_watched(uuid, title, nil, nil, new)
    {:noreply, assign(socket, :lib, %{lib | watched?: new})}
  end

  def handle_event("toggle_watched", _params, %{assigns: %{lib_busy: false}} = socket) do
    %{uuid: uuid, title: title, lib: lib} = socket.assigns
    new = not lib.all_watched?

    {:noreply,
     socket
     |> assign(:lib_busy, true)
     |> start_async(:bulk, fn ->
       Watch.set_series_watched(uuid, title, new)
       {new, Watch.library(uuid, title)}
     end)}
  end

  def handle_event("toggle_watched", _params, socket), do: {:noreply, socket}

  # Your TMDB rating (0.5–10, half steps): sent to TMDB through laev, shown beside TMDB's average.
  def handle_event("rate", %{"value" => v}, %{assigns: %{rating: %{state: :ok}}} = socket) do
    %{uuid: uuid, title: title} = socket.assigns

    case Float.parse(to_string(v)) do
      {value, _} ->
        {:noreply,
         start_async(socket, :rating, fn -> {:rate, Watch.rate(uuid, title, value)} end)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("rate", _params, socket), do: {:noreply, socket}

  def handle_event("clear_rating", _params, %{assigns: %{rating: %{state: :ok}}} = socket) do
    %{uuid: uuid, title: title} = socket.assigns
    {:noreply, start_async(socket, :rating, fn -> {:clear, Watch.clear_rating(uuid, title)} end)}
  end

  def handle_event("clear_rating", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_saved", _params, socket) do
    %{uuid: uuid, title: title, lib: lib} = socket.assigns
    saved? = Watch.toggle_saved(uuid, title) == :added
    {:noreply, assign(socket, :lib, %{lib | saved?: saved?})}
  end

  def handle_event("toggle_hold", _params, socket) do
    %{uuid: uuid, title: title, lib: lib} = socket.assigns
    held? = Watch.toggle_hold(uuid, title) == :held
    {:noreply, assign(socket, :lib, %{lib | held?: held?})}
  end

  def handle_event("toggle_episode", %{"season" => s, "episode" => e}, socket) do
    %{uuid: uuid, title: title, watched: watched} = socket.assigns

    with season when is_integer(season) <- to_int(s), ep when is_integer(ep) <- to_int(e) do
      new = not MapSet.member?(watched, ep)
      Watch.set_watched(uuid, title, season, ep, new)

      {:noreply,
       socket
       |> assign(:watched, if(new, do: MapSet.put(watched, ep), else: MapSet.delete(watched, ep)))
       |> assign(:lib, Watch.library(uuid, title))}
    else
      _ -> {:noreply, socket}
    end
  end

  # The whole season on screen: all marked, or — when they all are — all cleared.
  def handle_event("toggle_season", _params, %{assigns: %{episodes: eps}} = socket)
      when is_list(eps) do
    %{uuid: uuid, title: title, season: season, watched: watched} = socket.assigns
    out = for e <- eps, e.aired?, do: e.number
    all? = out != [] and Enum.all?(out, &MapSet.member?(watched, &1))
    Watch.set_many_watched(uuid, title, Enum.map(out, &{season, &1}), not all?)

    {:noreply,
     socket
     |> assign(
       :watched,
       if(all?,
         do: MapSet.difference(watched, MapSet.new(out)),
         else: MapSet.union(watched, MapSet.new(out))
       )
     )
     |> assign(:lib, Watch.library(uuid, title))}
  end

  def handle_event("toggle_season", _params, socket), do: {:noreply, socket}

  def handle_event("mark_watched", _params, socket) do
    %{uuid: uuid, ctx: ctx} = socket.assigns
    if uuid && ctx, do: Watch.mark_watched(uuid, ctx)
    {:noreply, finished(socket)}
  end

  def handle_event("more", _params, socket) do
    %{rest: rest, uuid: uuid, ctx: ctx, token: token, playable: have} = socket.assigns
    parent = self()

    {:noreply,
     socket
     |> assign(phase: {:working, "Checking more releases…"})
     |> start_async(:more, fn -> probe_more(parent, token, uuid, ctx, rest, have) end)}
  end

  # The player reports the playhead every few seconds. Laev does the arithmetic (what was
  # watched, what was skipped, when it counts as finished) exactly as it does for mpv.
  def handle_event("progress", %{"position" => position, "duration" => duration} = params, socket) do
    %{uuid: uuid, ctx: ctx} = socket.assigns

    if uuid && ctx && is_number(position) do
      case Watch.record_progress(uuid, ctx, position, duration || 0, params["paused"] == true) do
        {:finished, true} -> {:noreply, finished(socket)}
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("ended", _params, socket), do: {:noreply, maybe_autoplay(socket)}

  def handle_event("next", _params, socket) do
    case socket.assigns.up_next do
      {season, episode} ->
        {:noreply, socket |> patch(season, episode) |> begin(season, episode, false)}

      _ ->
        {:noreply, socket}
    end
  end

  # Which episode "Play" means: the one asked for, else the one chosen, else where the
  # user is in the show, else the first they have not watched.
  defp target(%{assigns: %{type: "movie"}}, _params), do: {nil, nil}

  defp target(_socket, %{"season" => s, "episode" => e}), do: {to_int(s), to_int(e)}

  defp target(%{assigns: a}, _params) do
    cond do
      a.episode -> {a.season, a.episode}
      true -> {a.season, suggested_episode(a)}
    end
  end

  defp suggested_episode(%{resume: %{"season" => s, "episode" => e}, season: s})
       when is_integer(e), do: e

  defp suggested_episode(%{episodes: eps, watched: watched}) when is_list(eps) do
    case Enum.find(eps, &(&1.aired? and not MapSet.member?(watched, &1.number))) do
      nil -> eps |> List.first() |> then(&(&1 && &1.number))
      ep -> ep.number
    end
  end

  defp suggested_episode(_), do: 1

  defp patch(socket, season, episode) do
    query = Enum.reject([s: season, e: episode], fn {_k, v} -> is_nil(v) end)

    push_patch(socket, to: ~p"/title/#{socket.assigns.type}/#{socket.assigns.id}?#{query}")
  end

  # ── the pipeline: sources → probe → choose → play ──────────────────

  defp begin(%{assigns: %{uuid: nil}} = socket, _s, _e, _m), do: socket
  defp begin(%{assigns: %{linked?: false}} = socket, _s, _e, _m), do: socket

  defp begin(socket, season, episode, force?) do
    token = socket.assigns.token + 1
    key = {socket.assigns.type, socket.assigns.id, season, episode}
    %{uuid: uuid, title: title, mode: mode} = socket.assigns
    parent = self()

    socket
    |> cancel_async(:pipeline)
    |> cancel_async(:playback)
    |> assign(
      token: token,
      season: season,
      episode: episode,
      phase: {:working, "Starting…"},
      probe: nil,
      playable: [],
      rest: [],
      current: nil,
      player: nil,
      external: nil,
      cache_info: nil,
      cache_key: key,
      up_next: nil,
      ctx: nil
    )
    |> start_async(:pipeline, fn ->
      pipeline(parent, token, uuid, title, season, episode, force?, mode, key)
    end)
  end

  # Runs in a task. Everything slow happens here; progress goes to the page as messages.
  # Sources found earlier (and still fresh) are used as they are: no search, no probing.
  # `force?` (the Retry button) skips them and looks again.
  defp pipeline(parent, token, uuid, title, season, episode, force?, mode, key) do
    web = Roki.Laev.web_settings(uuid)
    hours = SourceCache.hours(web)
    cached = if force?, do: nil, else: SourceCache.get(uuid, key, hours)

    with :ok <- Watch.subscription(uuid),
         ctx = Watch.ctx(uuid, title, season, episode),
         cap = Watch.ceiling(uuid, ctx, mode, web),
         {:ok, res} <-
           from_cache(token, ctx, cap, key, cached)
           |> fresh_if_none(fn ->
             search(parent, token, uuid, title, season, episode, ctx, cap, key, hours, force?)
           end) do
      {:ok, res}
    else
      {:error, reason} -> {:error, token, reason}
    end
  end

  defp from_cache(_token, _ctx, _cap, _key, nil), do: nil

  defp from_cache(token, ctx, cap, key, entry) do
    {:ok,
     %{
       token: token,
       ctx: ctx,
       playable: entry.playable,
       rest: entry.rest,
       cap: cap,
       key: key,
       cached_at: entry.at,
       good: entry.good
     }}
  end

  defp fresh_if_none(nil, fun), do: fun.()
  defp fresh_if_none(hit, _fun), do: hit

  defp search(parent, token, uuid, title, season, episode, ctx, cap, key, hours, force?) do
    say = fn msg -> send(parent, {:status, token, msg}) end
    say.("Searching for releases…")

    with {:ok, %{query: query, sources: found}} <-
           Watch.sources(title, season, episode, uuid, force?),
         sources = Watch.with_library(uuid, query, found),
         {:ok, sources} <- within_ceiling(uuid, sources, cap),
         {:ok, playable, rest} <- probe_until_playable(parent, token, uuid, ctx, sources, []) do
      if hours > 0, do: SourceCache.put(uuid, key, playable, rest)

      {:ok,
       %{
         token: token,
         ctx: ctx,
         playable: playable,
         rest: rest,
         cap: cap,
         key: key,
         cached_at: nil,
         good: nil
       }}
    end
  end

  # Strict mode: releases above the ceiling are not even checked.
  defp within_ceiling(uuid, sources, cap) do
    strict? = Roki.Laev.run(uuid, &Laev.Config.strict_resolution?/0)

    if strict? and cap do
      case Laev.Sources.at_most(sources, cap) do
        [] when sources != [] -> {:error, {:above_ceiling, length(sources), cap}}
        kept -> {:ok, kept}
      end
    else
      {:ok, sources}
    end
  end

  defp probe_until_playable(_parent, _token, _uuid, _ctx, [], []), do: {:error, :none_playable}

  defp probe_until_playable(parent, token, uuid, ctx, sources, acc) do
    {page, rest} = Watch.probe_page(sources)
    playable = probe_page(parent, token, uuid, ctx, page)
    ranked = Watch.attach_and_rank(uuid, acc ++ playable)

    cond do
      ranked != [] -> {:ok, ranked, rest}
      rest == [] -> {:error, :none_playable}
      true -> probe_until_playable(parent, token, uuid, ctx, rest, [])
    end
  end

  # One round of probing, 8 releases two at a time. Each answer is counted on the page as it
  # arrives; the task keeps the ones that play.
  defp probe_page(parent, token, uuid, ctx, page) do
    {:ok, agent} = Agent.start_link(fn -> %{done: 0, ok: []} end)
    total = length(page)
    send(parent, {:probe, token, 0, 0, total})

    notify = fn {:result, idx, source, result} ->
      {done, ok} =
        Agent.get_and_update(agent, fn st ->
          ok =
            if match?({:ok, _}, result), do: [{idx, source, elem(result, 1)} | st.ok], else: st.ok

          st = %{st | done: st.done + 1, ok: ok}
          {{st.done, length(st.ok)}, st}
        end)

      send(parent, {:probe, token, done, ok, total})
    end

    opts =
      [notify: notify, episode: ctx.episode] ++ if(ctx.anime, do: [], else: [season: ctx.season])

    Roki.Laev.run(uuid, fn -> Laev.Providers.probe_sources(Enum.with_index(page), opts) end)

    ok = Agent.get(agent, & &1.ok)
    Agent.stop(agent)

    ok |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {_i, source, stream} -> {source, stream} end)
  end

  defp probe_more(parent, token, uuid, ctx, rest, have) do
    {page, rest} = Watch.probe_page(rest)
    playable = probe_page(parent, token, uuid, ctx, page)
    {:ok, token, Watch.attach_and_rank(uuid, have ++ playable), rest}
  end

  defp play_pair(socket, {_source, stream} = pair) do
    %{uuid: uuid, ctx: ctx, token: token} = socket.assigns
    {source, _} = pair

    socket
    |> assign(current: pair, phase: {:working, "Preparing playback…"}, player: nil)
    |> start_async(:playback, fn ->
      case Watch.start(uuid, ctx, source, stream) do
        {:ok, player} -> {:ok, token, player}
        {:error, reason} -> {:error, token, reason}
      end
    end)
  end

  # A release for the user's own player: the direct link and the ways to open it.
  defp hand_over(socket, {source, stream} = pair) do
    %{uuid: uuid, ctx: ctx} = socket.assigns
    app = Roki.Laev.web_settings(uuid)["external_app"]
    external = Watch.external(uuid, ctx, source, stream)

    if socket.assigns.cache_key,
      do: SourceCache.mark_good(uuid, socket.assigns.cache_key, source.hash)

    name = external.filename || socket.assigns.title.title
    launch = launch_url(app, socket.assigns.platform, external.url, name)

    socket
    |> assign(
      current: pair,
      player: nil,
      external: Map.merge(external, %{app: app, launch: launch}),
      phase: :external
    )
    |> then(&if(launch, do: push_event(&1, "roki:launch", %{url: launch}), else: &1))
  end

  # The pipeline found what plays: play the best (laev's rule) or show the list.
  defp after_probe(socket, %{ctx: ctx, playable: playable, rest: rest, cap: cap} = res) do
    socket =
      assign(socket,
        ctx: ctx,
        playable: playable,
        rest: rest,
        cache_info: res.cached_at && %{at: res.cached_at},
        cache_key: res.key
      )

    socket =
      if res.cached_at,
        do: socket,
        else: update(socket, :cached, &MapSet.put(&1, res.key))

    external? = socket.assigns.mode == :external

    # Play means play: the best release is chosen and started, whatever the terminal app's
    # "auto-pick" setting says (the list below is for switching to another one).
    # The release that started last time goes first: it is known to work.
    choice =
      case Enum.find(playable, fn {source, _} -> res.good && source.hash == res.good end) do
        nil when external? -> Watch.auto_choice_external(playable, cap)
        nil -> Watch.auto_choice(playable, cap)
        pair -> {:play, pair}
      end

    case choice do
      {:play, pair} when external? -> hand_over(socket, pair)
      {:play, pair} -> play_pair(socket, pair)
      {:ask, why} -> assign(socket, phase: {:choose, why})
      _ -> assign(socket, phase: {:choose, nil})
    end
  end

  # ── what comes back from the tasks ─────────────────────────────────

  @impl true
  def handle_async(:title, {:ok, {:ok, title, resume, cached, lib, rating}}, socket) do
    socket =
      assign(socket,
        title: title,
        resume: resume,
        cached: cached,
        lib: lib || socket.assigns.lib,
        rating: rating_state(rating),
        page_title: title.title
      )

    {:noreply, select(socket)}
  end

  def handle_async(:rating, {:ok, {:rate, {:ok, value}}}, socket),
    do: {:noreply, assign(socket, rating: %{state: :ok, value: value}, rating_error: nil)}

  def handle_async(:rating, {:ok, {:clear, :ok}}, socket),
    do: {:noreply, assign(socket, rating: %{state: :ok, value: nil}, rating_error: nil)}

  def handle_async(:rating, _other, socket),
    do: {:noreply, assign(socket, :rating_error, "TMDB did not take that. Try again.")}

  def handle_async(:bulk, {:ok, {new, lib}}, socket) do
    socket = assign(socket, lib: lib, lib_busy: false)
    # The episode list on screen follows what was just marked.
    watched =
      case socket.assigns.episodes do
        eps when is_list(eps) and new ->
          for e <- eps, e.aired?, into: socket.assigns.watched, do: e.number

        eps when is_list(eps) ->
          MapSet.difference(socket.assigns.watched, MapSet.new(eps, & &1.number))

        _ ->
          socket.assigns.watched
      end

    {:noreply, assign(socket, :watched, watched)}
  end

  def handle_async(:bulk, _other, socket), do: {:noreply, assign(socket, :lib_busy, false)}

  def handle_async(:title, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :title_error, reason || true)}

  def handle_async(:title, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :title_error, reason)}

  def handle_async(:episodes, {:ok, {:ok, season, eps, watched}}, socket) do
    if season == socket.assigns.season,
      do: {:noreply, assign(socket, episodes: eps, watched: watched)},
      else: {:noreply, socket}
  end

  def handle_async(:episodes, _other, socket), do: {:noreply, assign(socket, episodes: [])}

  def handle_async(
        :pipeline,
        {:ok, {:ok, %{token: token} = res}},
        %{assigns: %{token: token}} = socket
      ),
      do: {:noreply, after_probe(socket, res)}

  def handle_async(
        :pipeline,
        {:ok, {:error, token, reason}},
        %{assigns: %{token: token}} = socket
      ),
      do: {:noreply, assign(socket, phase: {:failed, failure(reason)})}

  def handle_async(:pipeline, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, phase: {:failed, "Something went wrong (#{inspect(reason, limit: 3)})."})}

  def handle_async(:pipeline, _stale, socket), do: {:noreply, socket}

  def handle_async(
        :more,
        {:ok, {:ok, token, playable, rest}},
        %{assigns: %{token: token}} = socket
      ),
      do: {:noreply, more_checked(socket, playable, rest)}

  def handle_async(:more, _other, socket), do: {:noreply, assign(socket, phase: {:choose, nil})}

  def handle_async(:playback, {:ok, {:ok, token, player}}, %{assigns: %{token: token}} = socket) do
    %{uuid: uuid, ctx: ctx} = socket.assigns
    prefer = Watch.short_code(Watch.preferred_subs(uuid))
    play_id = player.remux_id || fallback_id(socket.assigns.current)

    data = %{
      url: player.url,
      hls: player.hls?,
      resume: player.resume_at,
      tracks: player.subtitles,
      prefer: prefer,
      key: play_id
    }

    socket = assign(socket, player: data, phase: :playing)
    mark_good(socket)

    # The release did not carry a subtitle in their language: fetch one if they have a provider.
    socket =
      if Enum.any?(player.subtitles, &(Watch.short_code(&1.lang) == prefer)),
        do: socket,
        else:
          start_async(socket, :ext_subs, fn ->
            {token, Watch.external_subtitle(uuid, ctx, play_id)}
          end)

    {:noreply, socket}
  end

  def handle_async(
        :playback,
        {:ok, {:error, token, reason}},
        %{assigns: %{token: token}} = socket
      ),
      do: {:noreply, playback_failed(socket, reason)}

  def handle_async(:playback, _other, socket), do: {:noreply, socket}

  def handle_async(
        :ext_subs,
        {:ok, {token, {:ok, track}}},
        %{assigns: %{token: token, player: %{} = player}} = socket
      ),
      do: {:noreply, assign(socket, :player, %{player | tracks: player.tracks ++ [track]})}

  def handle_async(:ext_subs, _other, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:status, token, text}, %{assigns: %{token: token}} = socket),
    do: {:noreply, assign(socket, phase: {:working, text})}

  def handle_info({:probe, token, done, ok, total}, %{assigns: %{token: token}} = socket),
    do:
      {:noreply,
       assign(socket,
         probe: %{done: done, ok: ok, total: total},
         phase: {:working, "Checking releases"}
       )}

  def handle_info(_stale, socket), do: {:noreply, socket}

  # A direct (non-remuxed) release has no remux id; subtitles written beside it need a stable one.
  defp fallback_id({source, stream}) do
    :crypto.hash(:sha256, "#{source.hash}-#{stream[:filename]}-#{stream[:filesize]}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # Watched this episode through: remember it on the page, and line up the next one.
  defp finished(socket) do
    %{type: type, season: season, episode: episode, episodes: eps} = socket.assigns

    socket =
      if type == "tv" and episode,
        do: update(socket, :watched, &MapSet.put(&1, episode)),
        else: socket

    assign(socket, :up_next, next_episode(socket.assigns.title, season, episode, eps))
  end

  defp next_episode(%{type: "tv"} = title, season, episode, eps) when is_integer(episode) do
    nexts = if is_list(eps), do: Enum.filter(eps, &(&1.number > episode and &1.aired?)), else: []

    cond do
      nexts != [] -> {season, hd(nexts).number}
      Enum.any?(title.seasons, &(&1.number == season + 1)) -> {season + 1, 1}
      true -> nil
    end
  end

  defp next_episode(_, _, _, _), do: nil

  defp maybe_autoplay(socket) do
    case {socket.assigns.up_next, socket.assigns.uuid && Watch.autoplay?(socket.assigns.uuid)} do
      {{season, episode}, true} ->
        socket |> patch(season, episode) |> begin(season, episode, false)

      _ ->
        socket
    end
  end

  # The release started: remember it for the next Play, in the cache and on the page.
  defp mark_good(%{assigns: %{cache_key: key, uuid: uuid, current: {source, _}}}) when key != nil,
    do: SourceCache.mark_good(uuid, key, source.hash)

  defp mark_good(_socket), do: :ok

  # Sources from the cache that no longer play (a link expired) are not worth a second try:
  # forget them and search again, once, without the user having to do anything.
  defp playback_failed(%{assigns: %{cache_info: %{}, cache_key: key}} = socket, _reason) do
    SourceCache.delete(socket.assigns.uuid, key)
    %{season: season, episode: episode} = socket.assigns
    begin(socket, season, episode, true)
  end

  defp playback_failed(socket, reason), do: assign(socket, phase: {:failed, failure(reason)})

  defp more_checked(socket, playable, rest) do
    with %{uuid: uuid, cache_key: key} when key != nil <- socket.assigns do
      SourceCache.put(uuid, key, playable, rest)
    end

    assign(socket, playable: playable, rest: rest, phase: {:choose, nil})
  end

  # What to tell the user when it did not work.
  defp failure(:no_provider),
    do: "No debrid account is connected. Add a Real-Debrid or TorBox key in Settings."

  defp failure({:expired, detail}),
    do: "Your debrid subscription isn't active — #{detail}. Renew it, then try again."

  defp failure(:no_sources), do: "No releases were found for this."

  defp failure(:none_playable),
    do: "None of the releases found can be played right now. Try again later, or another episode."

  defp failure({:above_ceiling, n, cap}),
    do:
      "Nothing at #{label(cap)} or below — #{n} found above it. (Settings → only list sources within the ceiling.)"

  defp failure(:busy),
    do:
      "The server is re-encoding other videos right now. Try again in a minute, or pick an h264 release."

  defp failure(:timeout),
    do: "Preparing the video took too long. Try again, or pick another release."

  defp failure(other) when is_binary(other), do: other

  defp failure(other),
    do: "Couldn't start that (#{inspect(other, limit: 3, printable_limit: 80)})."

  defp label("2160p"), do: "4K"
  defp label(r), do: r

  # ── view ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    # A film's page on a phone, before anything has been started, is exactly one screen: it does
    # not scroll. Once Play is pressed there is more (progress, releases, the player) and it does.
    assigns =
      assign(
        assigns,
        :locked?,
        assigns.type == "movie" and assigns.title != nil and assigns.linked? and
          assigns.phase == :idle and assigns.player == nil and assigns.external == nil and
          assigns.playable == [] and assigns.title_error == nil
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/title/#{@type}/#{@id}"}
    >
      <p :if={@title_error} class="alert alert-error">
        {if @uuid,
          do: "Couldn't load this title just now. Try again in a minute.",
          else: "Log in to open titles — they are read with your own TMDB key."}
      </p>

      <div :if={@title == nil and @title_error == nil} class="space-y-4" aria-busy="true">
        <div class="skeleton h-64 w-full rounded-box"></div>
        <div class="skeleton h-8 w-1/3 rounded"></div>
      </div>

      <div :if={@title} class="space-y-8">
        <.phone_hero
          title={@title}
          resume={@resume}
          phase={@phase}
          season={@season}
          mode={@mode}
          linked?={@linked?}
          lib={@lib}
          lib_busy={@lib_busy}
          rating={@rating}
          locked?={@locked?}
        />

        <.rate_sheet :if={@linked?} title={@title} rating={@rating} error={@rating_error} />

        <.hero
          rating={@rating}
          title={@title}
          resume={@resume}
          phase={@phase}
          season={@season}
          mode={@mode}
          linked?={@linked?}
          lib={@lib}
          lib_busy={@lib_busy}
          cached?={@type == "movie" and MapSet.member?(@cached, {"movie", @id, nil, nil})}
        />

        <.access_notice uuid={@uuid} linked?={@linked?} />

        <.cache_note :if={@cache_info} at={@cache_info.at} busy={match?({:working, _}, @phase)} />

        <.status :if={@phase != :idle} phase={@phase} probe={@probe} />

        <.external_panel
          :if={@external}
          external={@external}
          platform={@platform}
          title={@title}
          season={@season}
          episode={@episode}
        />

        <section :if={@player} class="space-y-3">
          <div class="flex flex-wrap items-center gap-3">
            <h2 class="min-w-0 flex-1 truncate text-xl font-semibold">
              {@title.title}{now_playing(@title, @season, @episode, @episodes)}
            </h2>
            <button :if={@up_next} phx-click="next" class="btn btn-primary btn-sm">
              Next episode →
            </button>
          </div>
          <.study_player player={@player} progress?={true} />
        </section>

        <.sources
          :if={@playable != []}
          playable={@playable}
          rest={@rest}
          current={@current}
          phase={@phase}
          mode={@mode}
        />

        <.episodes
          :if={@type == "tv"}
          title={@title}
          season={@season}
          episode={@episode}
          episodes={@episodes}
          watched={@watched}
          cached={@cached}
          title_id={@id}
          can_play?={@linked?}
        />

        <%!-- On a phone the Play bar is fixed to the screen's bottom; leave room under the page. --%>
        <div :if={!@locked?} class="h-36 sm:hidden" aria-hidden="true"></div>
      </div>
    </Layouts.app>
    """
  end

  attr :cached?, :boolean, default: false
  attr :title, :map, required: true
  attr :resume, :any, default: nil
  attr :phase, :any, required: true
  attr :season, :any, default: nil
  attr :mode, :atom, required: true
  attr :linked?, :boolean, default: false
  attr :lib, :map, required: true
  attr :lib_busy, :boolean, default: false
  attr :rating, :map, required: true

  defp hero(assigns) do
    ~H"""
    <section class="hidden gap-6 sm:flex">
      <div class="w-[8.5rem] shrink-0 space-y-3 sm:w-56 sm:space-y-4">
        <img
          :if={@title.poster}
          src={@title.poster}
          alt={@title.title}
          class="aspect-[2/3] w-full rounded-box bg-base-300 object-cover shadow-lg"
        />
        <div :if={!@title.poster} class="aspect-[2/3] w-full rounded-box bg-base-300"></div>

        <%!-- Under the poster, well away from Play: a slip here should not save or hold a title. --%>
        <.library_buttons :if={@linked?} title={@title} lib={@lib} busy={@lib_busy} rating={@rating} />
      </div>

      <div class="min-w-0 flex-1 space-y-3">
        <div>
          <h1 class="text-xl font-bold leading-tight tracking-tight sm:text-4xl">{@title.title}</h1>
          <p class="text-sm text-base-content/60">
            {meta(@title)}
          </p>
          <p :if={@title.tagline} class="mt-1 italic text-base-content/60">{@title.tagline}</p>
        </div>

        <p
          :if={@title.overview}
          class="line-clamp-6 max-w-3xl text-sm text-base-content/80 sm:line-clamp-none sm:text-base"
        >
          {@title.overview}
        </p>

        <div class="space-y-3 pt-2">
          <%!-- Where it plays, then the button: one decision above the other. --%>
          <.mode_switch :if={@linked?} mode={@mode} />

          <div class="flex flex-wrap items-center gap-3">
            <button
              phx-click="play"
              class="btn btn-primary btn-lg h-12 w-full gap-2 px-4 text-lg shadow-md sm:h-14 sm:w-auto sm:min-w-[15rem] sm:px-10 sm:text-xl"
              disabled={match?({:working, _}, @phase) or (@title.type == "tv" and @season == nil)}
            >
              <.icon name="hero-play-solid" class="h-6 w-6" />
              {if @title.type == "movie", do: play_label(@resume), else: play_label_tv(@resume)}
            </button>
            <span
              :if={@cached?}
              class="badge badge-success badge-outline gap-1"
              title="Sources are cached: plays right away"
            >
              ⚡ cached
            </span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :title, :map, required: true
  attr :lib, :map, required: true
  attr :busy, :boolean, default: false
  attr :rating, :map, required: true

  # What the terminal app has on a title: watched (and back), saved for later, on hold.
  defp library_buttons(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 sm:gap-3">
      <button
        phx-click="toggle_saved"
        class={[
          "btn h-auto min-h-10 w-full justify-start gap-2 px-3 py-2 text-left text-xs leading-tight sm:h-12 sm:gap-2.5 sm:px-4 sm:text-sm",
          @lib.saved? && "btn-primary"
        ]}
        title={if @lib.saved?, do: "Click to remove it from saved", else: "Keep it for later"}
      >
        <.icon
          name={if @lib.saved?, do: "hero-bookmark-solid", else: "hero-bookmark"}
          class="h-4 w-4 shrink-0 sm:h-5 sm:w-5"
        />
        {if @lib.saved?, do: "Saved for later", else: "Save for later"}
      </button>

      <button
        :if={not @title.anime?}
        phx-click="toggle_hold"
        class={[
          "btn h-auto min-h-10 w-full justify-start gap-2 px-3 py-2 text-left text-xs leading-tight sm:h-12 sm:gap-2.5 sm:px-4 sm:text-sm",
          @lib.held? && "btn-warning"
        ]}
        title={
          if @lib.held?, do: "Click to take it off hold", else: "Put it down without finishing it"
        }
      >
        <.icon
          name={if @lib.held?, do: "hero-pause-circle-solid", else: "hero-pause-circle"}
          class="h-4 w-4 shrink-0 sm:h-5 sm:w-5"
        />
        {if @lib.held?, do: "On hold", else: "Put on hold"}
      </button>

      <%!-- A film is watched or not; a series is "all watched" or not (episodes below one by one).
            The same button marks and unmarks. --%>
      <button
        :if={@title.type == "movie" or not @title.anime?}
        phx-click="toggle_watched"
        disabled={@busy}
        class={[
          "btn h-auto min-h-10 w-full justify-start gap-2 px-3 py-2 text-left text-xs leading-tight sm:h-12 sm:gap-2.5 sm:px-4 sm:text-sm",
          watched_state?(@title, @lib) && "btn-success"
        ]}
        title={
          if watched_state?(@title, @lib),
            do: "Click to mark as not watched",
            else: "Mark it as watched"
        }
      >
        <span :if={@busy} class="loading loading-spinner loading-xs"></span>
        <.icon
          :if={!@busy}
          name={
            if watched_state?(@title, @lib), do: "hero-check-circle-solid", else: "hero-check-circle"
          }
          class="h-4 w-4 shrink-0 sm:h-5 sm:w-5"
        />
        {watched_label(@title, @lib)}
      </button>

      <%!-- TMDB's average, and — once you have rated it — yours beside it in another colour. --%>
      <button
        phx-click={JS.show(to: "#rate-sheet", display: "flex")}
        class="btn h-auto min-h-10 w-full justify-between gap-2 px-3 py-2 text-xs sm:h-12 sm:px-4 sm:text-sm"
        title="Rate it on TMDB"
      >
        <span class="flex items-center gap-1.5">
          <.icon name="hero-star-solid" class="h-4 w-4 shrink-0 text-warning sm:h-5 sm:w-5" />
          <span class="font-semibold text-warning">{avg_text(@title)}</span>
        </span>
        <span :if={@rating.value} class="font-semibold text-info">You {fmt_rating(@rating.value)}</span>
        <span :if={!@rating.value} class="text-base-content/60">Rate</span>
      </button>
    </div>
    """
  end

  defp avg_text(%{vote: v}) when is_number(v) and v > 0, do: fmt_rating(Float.round(v * 1.0, 1))
  defp avg_text(_), do: "–"

  # 8.0 → "8", 8.5 → "8.5"
  defp fmt_rating(v) when is_number(v) do
    if v == trunc(v),
      do: Integer.to_string(trunc(v)),
      else: :erlang.float_to_binary(v * 1.0, decimals: 1)
  end

  defp watched_state?(%{type: "movie"}, lib), do: lib.watched?
  defp watched_state?(_title, lib), do: lib.all_watched?

  defp watched_label(%{type: "movie"}, %{watched?: true}), do: "Watched"
  defp watched_label(%{type: "movie"}, _lib), do: "Mark watched"
  defp watched_label(_title, %{all_watched?: true}), do: "All watched"
  defp watched_label(_title, _lib), do: "Mark all watched"

  defp meta(t) do
    [
      t.year,
      t.minutes && "#{t.minutes} min",
      t.type == "tv" && length(t.seasons) > 0 &&
        "#{length(t.seasons)} #{if length(t.seasons) == 1, do: "season", else: "seasons"}",
      t.vote && t.vote > 0 && "★ #{Float.round(t.vote * 1.0, 1)}",
      t.genres != [] && Enum.join(Enum.take(t.genres, 3), ", ")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp play_label(%{"updated_at" => _}), do: "Play"
  defp play_label(_), do: "Play"

  defp play_label_tv(%{"season" => s, "episode" => e}) when is_integer(s) and is_integer(e),
    do: "Continue S#{s} · E#{e}"

  defp play_label_tv(_), do: "Play"

  defp now_playing(%{type: "tv"}, season, episode, eps)
       when is_integer(season) and is_integer(episode) do
    name = if is_list(eps), do: Enum.find_value(eps, &(&1.number == episode && &1.name))
    " · S#{season}E#{episode}#{if name, do: " — #{name}"}"
  end

  defp now_playing(_, _, _, _), do: ""

  attr :uuid, :any, default: nil
  attr :linked?, :boolean, default: false

  defp access_notice(assigns) do
    ~H"""
    <div :if={@uuid == nil} class="alert text-sm">
      <span>Log in, and connect your debrid account through laev, to watch here.</span>
      <a href="/phoenix_kit/users/log-in" class="btn btn-sm">Log in</a>
    </div>
    <div :if={@uuid != nil and not @linked?} class="alert text-sm">
      <span>Connect laev on your shelf to watch here — your Real-Debrid or TorBox account does the streaming.</span>
      <.link navigate={~p"/"} class="btn btn-sm">Connect laev</.link>
    </div>
    """
  end

  attr :phase, :any, required: true
  attr :probe, :any, default: nil

  defp status(assigns) do
    ~H"""
    <div
      :if={match?({:working, _}, @phase)}
      class="flex flex-wrap items-center gap-3 rounded-box bg-base-200 p-4 text-sm"
    >
      <span class="loading loading-spinner loading-sm"></span>
      <span>{elem(@phase, 1)}</span>
      <span :if={@probe} class="text-base-content/60">
        {@probe.done}/{@probe.total} checked · {@probe.ok} {if @probe.ok == 1,
          do: "plays",
          else: "play"}
      </span>
    </div>
    <p :if={match?({:failed, _}, @phase)} class="alert alert-warning text-sm">{elem(@phase, 1)}</p>
    <p :if={match?({:choose, _}, @phase)} class="text-sm text-base-content/70">
      {choose_text(@phase)}
    </p>
    """
  end

  defp choose_text({:choose, nil}), do: "Pick a release."
  defp choose_text({:choose, why}), do: "#{why} — pick one yourself."

  attr :mode, :atom, default: :browser
  attr :playable, :list, required: true
  attr :rest, :list, required: true
  attr :current, :any, default: nil
  attr :phase, :any, required: true

  defp sources(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">
        Releases
        <span class="text-sm font-normal text-base-content/60">{length(@playable)} playable</span>
      </h2>
      <ul class="divide-y divide-base-300 rounded-box border border-base-300">
        <li
          :for={{{source, stream}, i} <- Enum.with_index(@playable)}
          class="flex items-center gap-3 p-3"
        >
          <div class="min-w-0 flex-1 space-y-1">
            <div class="truncate text-sm font-medium" title={source.name}>{source.name}</div>
            <div class="flex flex-wrap items-center gap-1.5 text-xs">
              <span :if={source.resolution} class="badge badge-sm badge-primary">{label(
                source.resolution
              )}</span>
              <span class="badge badge-sm badge-ghost">{source.size_human}</span>
              <span class="badge badge-sm badge-ghost">{provider(stream)}</span>
              <span
                :if={Watch.heavy?(source)}
                class="badge badge-sm badge-warning"
                title="Not h264: re-encoded on the server, slower to start"
              >re-encoded</span>
              <span :if={source[:cached] == :library} class="badge badge-sm badge-success">in your library</span>
              <span :if={source[:codec]} class="badge badge-sm badge-ghost">{source.codec}</span>
              <span :if={langs(source, stream) != ""} class="text-base-content/60">🔊 {langs(
                source,
                stream
              )}</span>
              <span :if={subs(stream) != ""} class="text-base-content/60">💬 {subs(stream)}</span>
            </div>
          </div>
          <button
            phx-click="choose"
            phx-value-idx={i}
            class="btn btn-sm"
            disabled={match?({:working, _}, @phase)}
          >
            {cond do
              @current && elem(@current, 0).hash == source.hash -> "Selected"
              @mode == :external -> "Open"
              true -> "Play"
            end}
          </button>
          <button
            :if={@mode == :browser}
            phx-click="choose"
            phx-value-idx={i}
            phx-value-via="external"
            class="btn btn-sm btn-ghost"
            title="Open this release in your external player"
            disabled={match?({:working, _}, @phase)}
          >
            External
          </button>
        </li>
      </ul>
      <button
        :if={@rest != []}
        phx-click="more"
        class="btn btn-sm btn-ghost"
        disabled={match?({:working, _}, @phase)}
      >
        Check {min(length(@rest), 8)} more of {length(@rest)} unchecked
      </button>
    </section>
    """
  end

  defp provider(%{provider: :torbox}), do: "TorBox"
  defp provider(_), do: "Real-Debrid"

  defp langs(source, stream) do
    case stream do
      %{tracks: %{audio: [_ | _] = audio}} ->
        audio |> Enum.map(&Watch.language/1) |> Enum.join(" · ")

      _ ->
        source |> Map.get(:langs, []) |> Enum.map(&Watch.language/1) |> Enum.join(" · ")
    end
  end

  defp subs(%{tracks: %{subs: [_ | _] = subs}}),
    do: subs |> Enum.map(&Watch.language/1) |> Enum.take(4) |> Enum.join(" · ")

  defp subs(_), do: ""

  attr :title, :map, required: true
  attr :season, :any, default: nil
  attr :episode, :any, default: nil
  attr :episodes, :any, default: nil
  attr :watched, :any, required: true
  attr :cached, :any, required: true
  attr :title_id, :integer, required: true
  attr :can_play?, :boolean, default: false

  defp episodes(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex flex-wrap items-center gap-3">
        <h2 class="flex-1 text-xl font-semibold">Episodes</h2>
        <button
          :if={@can_play? and is_list(@episodes) and @episodes != []}
          phx-click="toggle_season"
          class="btn btn-sm gap-1.5"
        >
          <.icon name="hero-check-circle" class="h-4 w-4" />
          {if season_all_watched?(@episodes, @watched),
            do: "Unmark season",
            else: "Mark season watched"}
        </button>
        <form :if={length(@title.seasons) > 1} phx-change="select_season" id="season-form">
          <select name="season" class="select select-sm select-bordered">
            <option :for={s <- @title.seasons} value={s.number} selected={s.number == @season}>
              {s.name || "Season #{s.number}"}
            </option>
          </select>
        </form>
      </div>

      <div :if={@episodes == nil} class="space-y-2" aria-busy="true">
        <div :for={_ <- 1..4} class="skeleton h-20 w-full rounded-box"></div>
      </div>
      <p :if={@episodes == []} class="text-base-content/60">No episodes listed for this season.</p>

      <ul :if={is_list(@episodes)} class="divide-y divide-base-300 rounded-box border border-base-300">
        <li
          :for={e <- @episodes}
          class={["flex gap-3 p-3", e.number == @episode && "bg-primary/5"]}
        >
          <div class="hidden h-[4.5rem] w-32 shrink-0 overflow-hidden rounded bg-base-300 sm:block">
            <img :if={e.still} src={e.still} alt="" loading="lazy" class="h-full w-full object-cover" />
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <span class="font-medium">{e.number}. {e.name}</span>
              <span :if={MapSet.member?(@watched, e.number)} class="badge badge-sm badge-success">Watched</span>
              <span
                :if={MapSet.member?(@cached, {"tv", @title_id, @season, e.number})}
                class="badge badge-sm badge-success badge-outline"
              >
                ⚡ cached
              </span>
            </div>
            <div class="text-xs text-base-content/60">
              {[e.air_date, e.minutes && "#{e.minutes} min"] |> Enum.filter(& &1) |> Enum.join(" · ")}
              <span :if={not e.aired?}> · not out yet</span>
            </div>
            <p :if={e.overview} class="mt-1 line-clamp-2 text-sm text-base-content/70">
              {e.overview}
            </p>
          </div>
          <div class="flex shrink-0 items-center gap-1 self-center">
            <button
              :if={@can_play? and e.aired?}
              phx-click="toggle_episode"
              phx-value-season={@season}
              phx-value-episode={e.number}
              class={[
                "btn btn-sm btn-ghost btn-square",
                MapSet.member?(@watched, e.number) && "text-success"
              ]}
              title={
                if MapSet.member?(@watched, e.number),
                  do: "Watched — click to unmark",
                  else: "Mark watched"
              }
              aria-label={
                if MapSet.member?(@watched, e.number), do: "Unmark watched", else: "Mark watched"
              }
            >
              <.icon
                name={
                  if MapSet.member?(@watched, e.number),
                    do: "hero-check-circle-solid",
                    else: "hero-check-circle"
                }
                class="h-5 w-5"
              />
            </button>
            <button
              :if={@can_play? and e.aired?}
              phx-click="play"
              phx-value-season={@season}
              phx-value-episode={e.number}
              class="btn btn-sm"
            >
              <.icon name="hero-play-solid" class="h-4 w-4" /> Play
            </button>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  attr :mode, :atom, required: true

  defp mode_switch(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-sm">
      <span class="hidden text-base-content/60 sm:inline">Play in</span>
      <div class="join">
        <button
          phx-click="set_mode"
          phx-value-mode="browser"
          class={["btn btn-xs join-item sm:btn-sm", @mode == :browser && "btn-primary"]}
        >
          Browser
        </button>
        <button
          phx-click="set_mode"
          phx-value-mode="external"
          class={["btn btn-xs join-item sm:btn-sm", @mode == :external && "btn-primary"]}
        >
          External player
        </button>
      </div>
      <span :if={@mode == :external} class="hidden text-base-content/60 sm:inline">
        full quality, 4K included; nothing is converted on the server
      </span>
    </div>
    """
  end

  attr :external, :map, required: true
  attr :platform, :atom, required: true
  attr :title, :map, required: true
  attr :season, :any, default: nil
  attr :episode, :any, default: nil

  defp external_panel(assigns) do
    url = assigns.external.url
    name = assigns.external.filename || assigns.title.title

    assigns =
      assign(assigns,
        url: url,
        links: external_links(url, name),
        m3u:
          "data:audio/x-mpegurl;charset=utf-8," <>
            URI.encode(
              "#EXTM3U\n#EXTINF:-1," <> name <> "\n" <> url <> "\n",
              &URI.char_unreserved?/1
            ),
        m3u_name: Path.rootname(name) <> ".m3u"
      )

    ~H"""
    <section
      id="external-panel"
      phx-mounted={Phoenix.LiveView.JS.dispatch("roki:reveal")}
      class="space-y-3 rounded-box border border-base-300 p-4"
    >
      <div>
        <h2 class="text-lg font-semibold">
          Opening in {app_label(@external.app)}{now_playing(@title, @season, @episode, nil)}
        </h2>
        <p class="break-all text-sm text-base-content/60">
          {@external.name}{if @external.resolution, do: " · #{label(@external.resolution)}"}
        </p>
      </div>

      <div class="flex flex-wrap gap-2">
        <a :if={@external.launch} href={@external.launch} class="btn btn-primary">
          Open in {app_label(@external.app)}
        </a>
        <a href={@m3u} download={@m3u_name} class="btn">Download .m3u</a>
        <button
          type="button"
          class="btn"
          data-url={@url}
          onclick="navigator.clipboard.writeText(this.dataset.url).then(() => { this.textContent = 'Copied' })"
        >
          Copy link
        </button>
        <button phx-click="mark_watched" class="btn btn-ghost">Mark as watched</button>
      </div>

      <details class="text-sm">
        <summary class="cursor-pointer text-base-content/60">Other apps</summary>
        <div class="mt-2 flex flex-wrap gap-2">
          <a :if={@platform != :ios} href={@links.vlc_ios} class="btn btn-sm">VLC (iPhone/iPad)</a>
          <a :if={@platform != :android} href={@links.vlc_android} class="btn btn-sm">
            VLC (Android)
          </a>
          <a :if={@platform != :desktop} href={@links.vlc_desktop} class="btn btn-sm">
            VLC (desktop)
          </a>
          <a href={@links.infuse} class="btn btn-sm">Infuse</a>
          <a href={@links.mpv} class="btn btn-sm">mpv</a>
        </div>
      </details>

      <p class="text-sm text-base-content/60">
        <span :if={@external.resume_at > 0}>
          You were at {format_time(@external.resume_at)}. Seek there in your player.
        </span>
        Your player can't report progress back, so use “Mark as watched” when you finish.
        The link is private to your debrid account; don't share it.
      </p>
    </section>
    """
  end

  defp app_label(app),
    do: Roki.Laev.web_setting_specs()["external_app"].labels[app] || "your player"

  # Where the chosen app is opened on this device; `nil` for the .m3u download, which is a
  # file the user opens themselves.
  defp launch_url("m3u", _platform, _url, _name), do: nil

  defp launch_url(app, platform, url, name) do
    links = external_links(url, name)

    case {app, platform} do
      {"infuse", _} -> links.infuse
      {"mpv", _} -> links.mpv
      {_, :ios} -> links.vlc_ios
      {_, :android} -> links.vlc_android
      {_, _} -> links.vlc_desktop
    end
  end

  # `vlc://` is registered by VLC on iOS and macOS; Android takes an intent; mpv needs the
  # mpv-handler protocol. All carry the same direct link.
  defp external_links(url, name) do
    enc = URI.encode_www_form(url)
    %URI{host: host} = uri = URI.parse(url)
    rest = url |> String.replace_prefix("#{uri.scheme}:", "")

    %{
      vlc_ios: "vlc-x-callback://x-callback-url/stream?url=#{enc}",
      vlc_android:
        "intent:#{rest}#Intent;scheme=#{uri.scheme};package=org.videolan.vlc;type=video/*;S.title=#{URI.encode_www_form(name)};end",
      vlc_desktop: "vlc://#{url}",
      infuse: "infuse://x-callback-url/play?url=#{enc}",
      mpv: "mpv://#{Base.url_encode64(url)}",
      host: host
    }
  end

  defp format_time(s) do
    s = trunc(s)
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)
    sec = rem(s, 60)
    if h > 0, do: "#{h}:#{pad(m)}:#{pad(sec)}", else: "#{m}:#{pad(sec)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  attr :at, :integer, required: true
  attr :busy, :boolean, default: false

  defp cache_note(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-sm text-base-content/70">
      <span class="badge badge-success badge-outline gap-1">⚡ cached sources</span>
      <span>found {ago(@at)}, nothing to check.</span>
      <button phx-click="retry" class="btn btn-xs" disabled={@busy}>Retry</button>
      <span class="text-base-content/50">looks for new ones</span>
    </div>
    """
  end

  defp ago(at) do
    secs = max(System.os_time(:second) - at, 0)

    cond do
      secs < 90 -> "just now"
      secs < 3600 -> "#{div(secs, 60)} min ago"
      true -> "#{div(secs, 3600)} h ago"
    end
  end

  defp season_all_watched?(episodes, watched) do
    out = for e <- episodes, e.aired?, do: e.number
    out != [] and Enum.all?(out, &MapSet.member?(watched, &1))
  end

  # ── the phone layout ───────────────────────────────────────────────

  attr :title, :map, required: true
  attr :resume, :any, default: nil
  attr :phase, :any, required: true
  attr :season, :any, default: nil
  attr :mode, :atom, required: true
  attr :linked?, :boolean, default: false
  attr :lib, :map, required: true
  attr :lib_busy, :boolean, default: false
  attr :rating, :map, required: true
  attr :locked?, :boolean, default: false

  # One screen on a phone: the title and its details on top, a large poster with the three icon
  # buttons beside it, the synopsis (tap for the full text and more facts), and Play pinned to
  # the bottom with where it plays just above it. Wider screens use `hero/1`.
  defp phone_hero(assigns) do
    assigns = assign(assigns, :busy?, match?({:working, _}, assigns.phase))

    ~H"""
    <section class={[
      "-mt-4 flex h-[calc(100svh-4.5rem-1px)] flex-col gap-3 pb-[calc(8.75rem+env(safe-area-inset-bottom))] sm:hidden",
      @locked? && "-mb-9"
    ]}>
      <div class="shrink-0">
        <h1 class="text-xl font-bold leading-tight">{@title.title}</h1>
        <p class="text-xs text-base-content/60">{meta(@title)}</p>
      </div>

      <%!-- The poster takes all the height there is between the title and the synopsis; the
            three buttons are a strip against the right edge of the screen. --%>
      <%!-- The row is a size container: the poster is sized in its units (two thirds of its height,
            but never more than 62% of its width), so it never depends on its own content — a
            percentage height plus an aspect ratio collapses to nothing in Safari. --%>
      <div class="flex min-h-0 flex-1 gap-3 px-2 [container-type:size]">
        <div class="relative aspect-[2/3] w-[min(66.6667cqh,62cqw)] shrink-0 overflow-hidden rounded-box bg-base-300 shadow-lg">
          <img
            :if={@title.poster}
            src={@title.poster}
            alt={@title.title}
            class="absolute inset-0 h-full w-full object-cover"
          />
        </div>

        <%!-- Icons only: saved, on hold, watched — three tiles sharing the height and the width left of
              the poster, the icon centred in each. The state is the colour; the label is the tooltip. --%>
        <div :if={@linked?} class="flex min-w-0 flex-1 flex-col gap-2">
          <.round_btn
            event="toggle_saved"
            on={@lib.saved?}
            icon="bookmark"
            label={if @lib.saved?, do: "Saved for later (tap to remove)", else: "Save for later"}
            on_class="btn-primary"
          />
          <.round_btn
            :if={not @title.anime?}
            event="toggle_hold"
            on={@lib.held?}
            icon="pause-circle"
            label={if @lib.held?, do: "On hold (tap to resume)", else: "Put on hold"}
            on_class="btn-warning"
          />
          <.round_btn
            :if={@title.type == "movie" or not @title.anime?}
            event="toggle_watched"
            on={watched_state?(@title, @lib)}
            icon="check-circle"
            label={
              if watched_state?(@title, @lib),
                do: "Watched (tap to unmark)",
                else: watched_label(@title, @lib)
            }
            on_class="btn-success"
            busy={@lib_busy}
          />
          <.rate_tile title={@title} rating={@rating} />
        </div>
      </div>

      <button
        :if={@title.overview}
        type="button"
        phx-click={JS.show(to: "#about-sheet", display: "flex")}
        class="shrink-0 text-left"
        aria-label="Read the full description and more details"
      >
        <span class="line-clamp-5 text-sm text-base-content/80">{@title.overview}</span>
        <span class="flex items-center gap-1 text-xs font-medium text-primary">
          More <.icon name="hero-chevron-up-micro" class="h-4 w-4" />
        </span>
      </button>

      <%!-- Glued to the bottom edge of the screen: where it plays, then Play. --%>
      <div class="fixed inset-x-0 bottom-0 z-30 space-y-2 border-t border-base-300 bg-base-100/95 px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-3 backdrop-blur">
        <div :if={@linked?} class="flex justify-center"><.mode_switch mode={@mode} /></div>
        <button
          phx-click="play"
          class="btn btn-primary btn-lg h-14 w-full gap-2 text-xl shadow-md"
          disabled={@busy? or (@title.type == "tv" and @season == nil)}
        >
          <.icon name="hero-play-solid" class="h-6 w-6" />
          {if @title.type == "movie", do: play_label(@resume), else: play_label_tv(@resume)}
        </button>
      </div>

      <.about_sheet title={@title} />
    </section>
    """
  end

  attr :event, :string, required: true
  attr :on, :boolean, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :on_class, :string, required: true
  attr :busy, :boolean, default: false

  defp round_btn(assigns) do
    ~H"""
    <button
      phx-click={@event}
      disabled={@busy}
      class={["btn h-auto min-h-0 w-full flex-1 rounded-box px-0", @on && @on_class]}
      title={@label}
      aria-label={@label}
    >
      <span :if={@busy} class="loading loading-spinner"></span>
      <.icon :if={!@busy} name={"hero-#{@icon}#{if @on, do: "-solid"}"} class="h-8 w-8" />
    </button>
    """
  end

  attr :title, :map, required: true

  # The synopsis in full and everything else TMDB says about the title, in a sheet that slides up
  # from the bottom; tap outside, the cross, or Escape to close.
  defp about_sheet(assigns) do
    assigns = assign(assigns, :facts, facts(assigns.title))

    ~H"""
    <div
      id="about-sheet"
      class="fixed inset-0 z-[70] hidden items-end bg-black/50"
      phx-window-keydown={JS.hide(to: "#about-sheet")}
      phx-key="escape"
    >
      <div
        class="max-h-[85svh] w-full overflow-y-auto rounded-t-2xl bg-base-100 p-5 pb-8 shadow-2xl"
        phx-click-away={JS.hide(to: "#about-sheet")}
      >
        <div class="flex items-start gap-3">
          <div class="min-w-0 flex-1">
            <h2 class="text-lg font-bold leading-tight">{@title.title}</h2>
            <p
              :if={@title.original_title && @title.original_title != @title.title}
              class="text-xs text-base-content/60"
            >
              {@title.original_title}
            </p>
          </div>
          <button
            type="button"
            phx-click={JS.hide(to: "#about-sheet")}
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>

        <p :if={@title.tagline} class="mt-2 text-sm italic text-base-content/60">{@title.tagline}</p>

        <div :if={@title.genres != []} class="mt-3 flex flex-wrap gap-1.5">
          <span :for={g <- @title.genres} class="badge badge-ghost">{g}</span>
        </div>

        <p :if={@title.overview} class="mt-4 text-sm leading-relaxed text-base-content/90">
          {@title.overview}
        </p>

        <dl class="mt-5 grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
          <%= for {label, value} <- @facts do %>
            <dt class="text-base-content/50">{label}</dt>
            <dd>{value}</dd>
          <% end %>
        </dl>
      </div>
    </div>
    """
  end

  # What the sheet lists besides the genres: only what TMDB knows.
  defp facts(t) do
    [
      {"Released", date_text(t.date, t.type)},
      {"Last aired",
       t.type == "tv" && t.last_air_date != t.date && date_text(t.last_air_date, "tv")},
      {"Runtime", t.minutes && "#{t.minutes} min"},
      {"Seasons", t.type == "tv" && t.seasons != [] && length(t.seasons)},
      {"Episodes", t.episodes_total && t.episodes_total > 0 && t.episodes_total},
      {"Rating",
       t.vote && t.vote > 0 &&
         "★ #{Float.round(t.vote * 1.0, 1)}#{if t.vote_count && t.vote_count > 0, do: " (#{thousands(t.vote_count)} votes)"}"},
      {"Status", t.status},
      {"Language", t.language && Watch.language(t.language)},
      {"Also spoken", also_spoken(t)},
      {"Country", t.countries != [] && Enum.join(t.countries, ", ")},
      {(t.type == "tv" && "Network") || "Studio",
       (t.type == "tv" && t.networks != [] && Enum.join(Enum.take(t.networks, 3), ", ")) ||
         (t.studios != [] && Enum.join(Enum.take(t.studios, 3), ", "))}
    ]
    |> Enum.filter(fn {_label, value} -> value not in [nil, false, ""] end)
  end

  defp also_spoken(t) do
    others = t.spoken -- [t.language && Watch.language(t.language)]
    if others == [], do: nil, else: Enum.join(others, ", ")
  end

  # "18 Dec 1968 (57 years ago)" — or "(in 55 days)" for what is not out yet.
  defp date_text(nil, _type), do: nil

  defp date_text(iso, _type) do
    case Date.from_iso8601(iso) do
      {:ok, d} ->
        days = Date.diff(Date.utc_today(), d)

        ago =
          cond do
            days < 0 -> "in #{-days} days"
            days == 0 -> "today"
            days < 60 -> "#{days} days ago"
            days < 730 -> "#{div(days, 30)} months ago"
            true -> "#{div(days, 365)} years ago"
          end

        "#{Calendar.strftime(d, "%-d %b %Y")} (#{ago})"

      _ ->
        iso
    end
  end

  defp thousands(n) when is_integer(n),
    do:
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

  defp thousands(n), do: to_string(n)

  attr :title, :map, required: true
  attr :rating, :map, required: true

  # The phone's rating tile: TMDB's average on top, yours under it once you have rated.
  defp rate_tile(assigns) do
    ~H"""
    <button
      phx-click={JS.show(to: "#rate-sheet", display: "flex")}
      class="btn h-auto min-h-0 w-full flex-1 flex-col gap-0 rounded-box px-0 leading-tight"
      title="Rate it on TMDB"
      aria-label="Rate it on TMDB"
    >
      <span class="flex items-center gap-1 text-base font-bold text-warning">
        <.icon name="hero-star-solid" class="h-4 w-4" />{avg_text(@title)}
      </span>
      <span :if={@rating.value} class="text-sm font-bold text-info">You {fmt_rating(@rating.value)}</span>
      <span :if={!@rating.value} class="text-xs font-normal text-base-content/60">Rate</span>
    </button>
    """
  end

  attr :title, :map, required: true
  attr :rating, :map, required: true
  attr :error, :string, default: nil

  # Where you rate: TMDB's score for reference, a half-step slider, save or take it back.
  defp rate_sheet(assigns) do
    ~H"""
    <div
      id="rate-sheet"
      class="fixed inset-0 z-[70] hidden items-end bg-black/50 sm:items-center sm:justify-center"
      phx-window-keydown={JS.hide(to: "#rate-sheet")}
      phx-key="escape"
    >
      <div
        class="w-full rounded-t-2xl bg-base-100 p-5 pb-8 shadow-2xl sm:max-w-sm sm:rounded-2xl sm:pb-5"
        phx-click-away={JS.hide(to: "#rate-sheet")}
      >
        <div class="flex items-start gap-3">
          <div class="min-w-0 flex-1">
            <h2 class="text-lg font-bold leading-tight">Rate {@title.title}</h2>
            <p class="text-sm text-base-content/60">
              <span class="font-semibold text-warning">★ {avg_text(@title)}</span>
              on TMDB<span :if={@title.vote_count && @title.vote_count > 0}> · {thousands(
                @title.vote_count
              )} votes</span>
            </p>
          </div>
          <button
            type="button"
            phx-click={JS.hide(to: "#rate-sheet")}
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>

        <p :if={@rating.state == :no_account} class="mt-4 text-sm text-base-content/70">
          Ratings are sent with your TMDB account, which isn't linked in laev yet. Link it in the
          terminal app (it comes across with your keys), then rate here.
        </p>

        <form
          :if={@rating.state == :ok}
          id="rate-form"
          phx-submit={JS.push("rate") |> JS.hide(to: "#rate-sheet")}
          class="mt-4 space-y-4"
        >
          <div class="text-center">
            <span id="rate-out" class="text-4xl font-bold text-info">{fmt_rating(@rating.value || 7)}</span>
            <span class="text-lg text-base-content/50"> / 10</span>
          </div>
          <input
            type="range"
            name="value"
            min="0.5"
            max="10"
            step="0.5"
            value={@rating.value || 7}
            oninput="document.getElementById('rate-out').textContent = Number(this.value) % 1 === 0 ? String(Number(this.value)) : Number(this.value).toFixed(1)"
            class="range range-info w-full"
            aria-label="Your rating"
          />
          <div class="flex gap-2">
            <button type="submit" class="btn btn-info flex-1">Save rating</button>
            <button
              :if={@rating.value}
              type="button"
              phx-click={JS.push("clear_rating") |> JS.hide(to: "#rate-sheet")}
              class="btn btn-ghost"
            >
              Remove
            </button>
          </div>
          <p :if={@rating.value} class="text-center text-xs text-base-content/60">
            Your rating: <span class="font-semibold text-info">{fmt_rating(@rating.value)}</span>
          </p>
        </form>

        <p :if={@rating.state == :loading} class="mt-4 text-sm text-base-content/60">Loading…</p>
        <p :if={@error} class="mt-3 text-sm text-error">{@error}</p>
      </div>
    </div>
    """
  end
end
