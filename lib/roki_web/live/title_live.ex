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
    do: if(connect_param(socket, "player") == "external", do: :external, else: :browser)

  defp platform_param(socket) do
    case connect_param(socket, "platform") do
      p when p in ["ios", "android"] -> String.to_existing_atom(p)
      _ -> :desktop
    end
  end

  defp connect_param(socket, key) do
    if connected?(socket), do: (get_connect_params(socket) || %{})[key]
  end

  defp load_title(type, id, uuid) do
    with {:ok, title} <- Watch.title(type, id, uuid) do
      resume =
        if uuid && Roki.Laev.connected?(uuid),
          do: Roki.Laev.run(uuid, fn -> Laev.Resume.get(type, id) end)

      {:ok, title, resume}
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
  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ["browser", "external"] do
    {:noreply,
     socket
     |> assign(mode: String.to_existing_atom(mode))
     |> push_event("roki:player", %{mode: mode})}
  end

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
  def handle_event("progress", %{"position" => position, "duration" => duration}, socket) do
    %{uuid: uuid, ctx: ctx} = socket.assigns

    if uuid && ctx && is_number(position) do
      case Watch.record_progress(uuid, ctx, position, duration || 0) do
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

  defp begin(socket, season, episode, manual?) do
    token = socket.assigns.token + 1
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
      up_next: nil,
      ctx: nil
    )
    |> start_async(:pipeline, fn ->
      pipeline(parent, token, uuid, title, season, episode, manual?, mode)
    end)
  end

  # Runs in a task. Everything slow happens here; progress goes to the page as messages.
  defp pipeline(parent, token, uuid, title, season, episode, _manual?, mode) do
    say = fn msg -> send(parent, {:status, token, msg}) end

    with :ok <- Watch.subscription(uuid),
         ctx = Watch.ctx(uuid, title, season, episode),
         _ = say.("Searching for releases…"),
         {:ok, %{query: query, sources: found}} <- Watch.sources(title, season, episode, uuid),
         sources = Watch.with_library(uuid, query, found),
         cap = Watch.device_cap(Watch.ceiling(uuid, ctx), mode, Roki.Laev.web_settings(uuid)),
         {:ok, sources} <- within_ceiling(uuid, sources, cap),
         {:ok, playable, rest} <- probe_until_playable(parent, token, uuid, ctx, sources, []) do
      {:ok, %{token: token, ctx: ctx, playable: playable, rest: rest, cap: cap}}
    else
      {:error, reason} -> {:error, token, reason}
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
    external = Watch.external(uuid, ctx, source, stream)
    assign(socket, current: pair, player: nil, external: external, phase: :external)
  end

  # The pipeline found what plays: play the best (laev's rule) or show the list.
  defp after_probe(socket, %{ctx: ctx, playable: playable, rest: rest, cap: cap}) do
    socket = assign(socket, ctx: ctx, playable: playable, rest: rest)
    auto? = Watch.auto_source?(socket.assigns.uuid)
    external? = socket.assigns.mode == :external

    choice =
      cond do
        not auto? -> nil
        external? -> Watch.auto_choice_external(playable, cap)
        true -> Watch.auto_choice(playable, cap)
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
  def handle_async(:title, {:ok, {:ok, title, resume}}, socket) do
    socket = assign(socket, title: title, resume: resume, page_title: title.title)
    {:noreply, select(socket)}
  end

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
      do: {:noreply, assign(socket, playable: playable, rest: rest, phase: {:choose, nil})}

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
      do: {:noreply, assign(socket, phase: {:failed, failure(reason)})}

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
        <.hero title={@title} resume={@resume} phase={@phase} season={@season} />

        <.access_notice uuid={@uuid} linked?={@linked?} />

        <.mode_switch :if={@linked?} mode={@mode} />

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
          can_play?={@linked?}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :title, :map, required: true
  attr :resume, :any, default: nil
  attr :phase, :any, required: true
  attr :season, :any, default: nil

  defp hero(assigns) do
    ~H"""
    <section class="flex flex-col gap-6 sm:flex-row">
      <div class="w-40 shrink-0 sm:w-56">
        <img
          :if={@title.poster}
          src={@title.poster}
          alt={@title.title}
          class="aspect-[2/3] w-full rounded-box bg-base-300 object-cover shadow-lg"
        />
        <div :if={!@title.poster} class="aspect-[2/3] w-full rounded-box bg-base-300"></div>
      </div>

      <div class="min-w-0 flex-1 space-y-3">
        <div>
          <h1 class="text-2xl font-bold tracking-tight sm:text-4xl">{@title.title}</h1>
          <p class="text-sm text-base-content/60">
            {meta(@title)}
          </p>
          <p :if={@title.tagline} class="mt-1 italic text-base-content/60">{@title.tagline}</p>
        </div>

        <p :if={@title.overview} class="max-w-3xl text-base-content/80">{@title.overview}</p>

        <div class="flex flex-wrap items-center gap-2 pt-1">
          <button
            :if={@title.type == "movie"}
            phx-click="play"
            class="btn btn-primary"
            disabled={match?({:working, _}, @phase)}
          >
            <.icon name="hero-play-solid" class="h-5 w-5" /> {play_label(@resume)}
          </button>
          <button
            :if={@title.type == "tv"}
            phx-click="play"
            class="btn btn-primary"
            disabled={match?({:working, _}, @phase) or @season == nil}
          >
            <.icon name="hero-play-solid" class="h-5 w-5" /> {play_label_tv(@resume)}
          </button>
        </div>
      </div>
    </section>
    """
  end

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
            title="Open in VLC or another player on this device"
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
  attr :can_play?, :boolean, default: false

  defp episodes(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex flex-wrap items-center gap-3">
        <h2 class="flex-1 text-xl font-semibold">Episodes</h2>
        <form :if={length(@title.seasons) > 1} phx-change="select_season">
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
            </div>
            <div class="text-xs text-base-content/60">
              {[e.air_date, e.minutes && "#{e.minutes} min"] |> Enum.filter(& &1) |> Enum.join(" · ")}
              <span :if={not e.aired?}> · not out yet</span>
            </div>
            <p :if={e.overview} class="mt-1 line-clamp-2 text-sm text-base-content/70">
              {e.overview}
            </p>
          </div>
          <div class="shrink-0 self-center">
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
      <span class="text-base-content/60">Play in</span>
      <div class="join">
        <button
          phx-click="set_mode"
          phx-value-mode="browser"
          class={["btn btn-sm join-item", @mode == :browser && "btn-primary"]}
        >
          This page
        </button>
        <button
          phx-click="set_mode"
          phx-value-mode="external"
          class={["btn btn-sm join-item", @mode == :external && "btn-primary"]}
        >
          VLC / external player
        </button>
      </div>
      <span :if={@mode == :external} class="text-base-content/60">
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
          Ready for your player{now_playing(@title, @season, @episode, nil)}
        </h2>
        <p class="break-all text-sm text-base-content/60">
          {@external.name}{if @external.resolution, do: " · #{label(@external.resolution)}"}
        </p>
      </div>

      <div class="flex flex-wrap gap-2">
        <a :if={@platform == :ios} href={@links.vlc_ios} class="btn btn-primary">Open in VLC</a>
        <a :if={@platform == :android} href={@links.vlc_android} class="btn btn-primary">
          Open in VLC
        </a>
        <a :if={@platform == :desktop} href={@links.vlc_desktop} class="btn btn-primary">
          Open in VLC
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
end
