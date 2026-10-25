defmodule RokiWeb.WatchLive do
  @moduledoc """
  `/watch/movie/:id` and `/watch/tv/:id/:season/:episode` (`?h=` the release's info hash) — the
  player page: the video on the left, the subtitle sidebar on the right.

  The address says what to play, so it can be copied and sent (the other person needs their own
  debrid set up), reloaded, and the back button returns to the sources. With a `?h=` it plays that
  release (found among the checked ones for the title); without one, the best, and the address is
  then updated to name it. Position and progress go back through laev as everywhere else.
  """
  use RokiWeb, :live_view

  import RokiWeb.StudyComponents
  import RokiWeb.WatchComponents, only: [now_playing: 3, checks_list: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Watch
  alias Roki.Watch.{Resolver, SourceCache}

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    type = if params["season"], do: "tv", else: "movie"

    with {n, ""} <- Integer.parse(id),
         {season, episode} <- parse_episode(params),
         scope = socket.assigns[:phoenix_kit_current_scope],
         uuid = if(scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)),
         # Playing here can make the server convert the video: only for the accounts allowed to.
         true <- uuid == nil or Roki.Keys.browser?(uuid) or {:allowed, false, n} do
      # Study mode (`?study=1`): this title in the languages remembered for it, the account's own
      # settings untouched. Everything this page runs in is bound to them.
      study = if params["study"] == "1" and uuid, do: Roki.Study.get(uuid, type, n)
      # Only in the live process: the page's first (static) render runs in a connection's process,
      # which is reused for other requests.
      if connected?(socket), do: Roki.Study.bind(Roki.Study.overrides(study))

      socket =
        assign(socket,
          study: study,
          page_title: "Watch",
          type: type,
          id: n,
          season: season,
          episode: episode,
          hash: nil,
          prefer: nil,
          uuid: uuid,
          linked?: uuid != nil and Roki.Laev.connected?(uuid),
          title: nil,
          title_error: nil,
          token: 0,
          status: "Starting…",
          probe: nil,
          checks: [],
          ctx: nil,
          key: nil,
          current: nil,
          player: nil,
          failed: nil,
          episodes: nil,
          up_next: nil,
          up_prev: nil
        )

      {:ok, if(connected?(socket) and socket.assigns.linked?, do: load(socket), else: socket)}
    else
      {:allowed, false, n} ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "Watching in the browser isn't switched on for this account. Use an external player (VLC, mpv)."
         )
         |> push_navigate(to: ~p"/title/#{type}/#{n}")}

      _ ->
        {:ok, push_navigate(socket, to: ~p"/home")}
    end
  end

  defp parse_episode(%{"season" => s, "episode" => e}) do
    with {season, ""} <- Integer.parse(s),
         {episode, ""} <- Integer.parse(e),
         do: {season, episode}
  end

  defp parse_episode(_), do: {nil, nil}

  @impl true
  def handle_params(params, _uri, socket) do
    hash = if params["h"] in [nil, ""], do: nil, else: String.slice(params["h"], 0, 64)
    # `prefer`: the release the previous episode played from — kept if the next one has it too.
    prefer =
      if params["prefer"] in [nil, ""], do: nil, else: String.slice(params["prefer"], 0, 64)

    {:noreply, assign(socket, hash: hash, prefer: prefer)}
  end

  defp load(socket) do
    %{type: type, id: id, uuid: uuid} = socket.assigns
    start_async(socket, :title, Roki.Study.wrap(fn -> Watch.title(type, id, uuid) end))
  end

  # The title is known: find the release, start it, and (for a series) fetch the season's
  # episodes so the next one is known.
  defp resolve(socket) do
    token = socket.assigns.token + 1

    %{uuid: uuid, title: title, season: season, episode: episode, hash: hash, prefer: prefer} =
      socket.assigns

    parent = self()

    socket
    |> assign(token: token, failed: nil, player: nil, checks: [])
    |> start_async(
      :resolve,
      Roki.Study.wrap(fn ->
        with {:ok, res} <-
               Resolver.run(parent, token, uuid, title, season, episode, false, :browser, true),
             {res, pair} <-
               locate(parent, token, uuid, res, hash || prefer, if(hash, do: 3, else: 1)),
             pair = if(hash, do: pair, else: within_cap(res, pair)),
             {:ok, pair} <- choose(res, pair),
             :ok <- announce(parent, token, "Getting the video ready…"),
             {:ok, player} <- start(uuid, res.ctx, pair) do
          {:ok, token, res, pair, player}
        else
          {:error, ^token, reason} -> {:error, token, reason}
          {:error, reason} -> {:error, token, reason}
        end
      end)
    )
  end

  # A shared address names a release. It may not be among the first ones checked, so look further
  # (a few pages) before settling for the best.
  defp locate(_parent, _token, _uuid, res, nil, _pages), do: {res, nil}

  defp locate(parent, token, uuid, res, hash, pages) do
    case Resolver.find(res.playable, hash) do
      nil when pages > 0 and res.rest != [] ->
        hours = SourceCache.hours(Roki.Laev.web_settings(uuid))

        {:ok, _token, all, rest} =
          Resolver.more(parent, token, uuid, res.ctx, res.rest, res.playable, res.key, hours)

        locate(parent, token, uuid, %{res | playable: all, rest: rest}, hash, pages - 1)

      pair ->
        {res, pair}
    end
  end

  # The release the last episode used (a hint, not a request) only counts when this player takes it.
  defp within_cap(_res, nil), do: nil

  defp within_cap(res, {source, _} = pair),
    do: if(Laev.Sources.resolution_at_most?(source.resolution, res.cap), do: pair)

  defp announce(parent, token, text) do
    send(parent, {:status, token, text})
    :ok
  end

  defp choose(res, nil) do
    case pick(res) do
      nil -> {:error, :none_playable}
      pair -> {:ok, pair}
    end
  end

  defp choose(_res, pair), do: {:ok, pair}

  defp pick(res) do
    case Resolver.pick(res.playable, res.cap, res.good, :browser) do
      {:play, pair} -> pair
      _ -> List.first(res.playable)
    end
  end

  # The languages offered as OpenSubtitles choices: theirs first, then the usual few.
  defp os_langs(prefer),
    do:
      Enum.uniq(
        Enum.reject([prefer, "en", "fr", "ja", "es", "de", "pt", "it", "ru"], &(&1 in [nil, ""]))
      )

  defp start(uuid, ctx, {source, stream}), do: Watch.start(uuid, ctx, source, stream)

  @impl true
  def handle_async(:title, {:ok, {:ok, title}}, socket) do
    %{uuid: uuid, season: season, episode: episode} = socket.assigns
    title = Map.put(title, :tag, Watch.episode_tag(uuid, title, season, episode))
    socket = assign(socket, title: title, page_title: title.title)

    socket =
      if socket.assigns.type == "tv",
        do: load_episodes(socket),
        else: socket

    {:noreply, resolve(socket)}
  end

  def handle_async(:title, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :title_error, reason || true)}

  def handle_async(:title, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :title_error, reason)}

  def handle_async(
        :resolve,
        {:ok, {:ok, token, res, pair, player}},
        %{assigns: %{token: token}} = socket
      ) do
    %{uuid: uuid} = socket.assigns
    {source, _} = pair
    prefer = Watch.short_code(Watch.preferred_subs(uuid))
    play_id = player.remux_id || fallback_id(pair)
    # Files picked from OpenSubtitles before: back from the disk copy, no request.
    saved = Watch.os_saved(uuid, "#{res.ctx.type}:#{res.ctx.tmdb_id}", play_id)

    data = %{
      url: player.url,
      hls: player.hls?,
      resume: player.resume_at,
      tracks: player.subtitles ++ saved,
      prefer: prefer,
      key: play_id,
      media: "#{res.ctx.type}:#{res.ctx.tmdb_id}",
      os: Watch.os_state(uuid),
      os_langs: os_langs(prefer)
    }

    if res.key, do: SourceCache.mark_good(uuid, res.key, source.hash)

    Process.send_after(self(), :warm_next, 45_000)

    socket =
      socket
      |> assign(player: data, current: pair, ctx: res.ctx, key: res.key)
      |> with_neighbours()
      |> name_the_release(source.hash)

    # What the release did not carry: their language, and for anime the original Japanese
    # (Jimaku), each fetched on its own so a slow provider holds up nothing.
    socket =
      for lang <- Watch.external_langs(uuid, res.ctx, player.subtitles ++ saved),
          reduce: socket do
        acc ->
          start_async(
            acc,
            {:ext_subs, lang},
            Roki.Study.wrap(fn ->
              {token, external(uuid, res.ctx, play_id, lang, source.name)}
            end)
          )
      end

    {:noreply, socket}
  end

  def handle_async(
        :resolve,
        {:ok, {:error, token, reason}},
        %{assigns: %{token: token}} = socket
      ),
      do: {:noreply, assign(socket, :failed, Resolver.failure(reason))}

  def handle_async(:resolve, {:exit, reason}, socket),
    do:
      {:noreply, assign(socket, :failed, "Something went wrong (#{inspect(reason, limit: 3)}).")}

  def handle_async(:resolve, _stale, socket), do: {:noreply, socket}

  def handle_async(
        {:ext_subs, _lang},
        {:ok, {token, {:ok, track}}},
        %{assigns: %{token: token, player: %{} = player}} = socket
      ),
      do:
        {:noreply, assign(socket, :player, %{player | tracks: player.tracks ++ List.wrap(track)})}

  def handle_async({:ext_subs, _lang}, _other, socket), do: {:noreply, socket}

  def handle_async(:episodes, {:ok, {:ok, eps}}, socket) do
    socket = assign(socket, :episodes, eps)
    {:noreply, socket |> assign(:up_next, next_episode(socket.assigns)) |> with_neighbours()}
  end

  def handle_async(:prev, {:ok, {_s, _e, _tag} = prev}, socket),
    do: {:noreply, socket |> assign(:up_prev, prev) |> with_neighbours()}

  def handle_async(:prev, _other, socket), do: {:noreply, socket}

  def handle_async(:episodes, _other, socket), do: {:noreply, socket}

  # Japanese for anime is every plausible file Jimaku has (they differ in timing); anything else
  # is the one best match laev finds.
  defp external(uuid, %{anime: true} = ctx, play_id, "ja", source_name) do
    case Watch.jimaku_tracks(uuid, ctx, play_id, source_name) do
      {:ok, _} = ok -> ok
      _ -> Watch.external_subtitle(uuid, ctx, play_id, "ja")
    end
  end

  defp external(uuid, ctx, play_id, lang, _source_name),
    do: Watch.external_subtitle(uuid, ctx, play_id, lang)

  # The player's "Previous" and "Next" buttons need to know what the neighbours are called.
  defp with_neighbours(%{assigns: %{player: %{} = player, title: title, uuid: uuid}} = socket)
       when title != nil do
    player =
      case socket.assigns.up_next do
        {s, e} -> Map.put(player, :next, Watch.episode_tag(uuid, title, s, e))
        _ -> player
      end

    player =
      case socket.assigns.up_prev do
        {_s, _e, tag} -> Map.put(player, :prev, tag)
        _ -> player
      end

    assign(socket, :player, player)
  end

  defp with_neighbours(socket), do: socket

  # The address names the release that is playing, so a reload — or a copy of it — plays the same.
  defp name_the_release(%{assigns: %{hash: nil}} = socket, hash),
    do: push_patch(socket, to: watch_path(socket.assigns, hash), replace: true)

  defp name_the_release(socket, _hash), do: socket

  defp load_episodes(socket) do
    %{id: id, season: season, uuid: uuid, title: title, episode: episode} = socket.assigns

    socket
    |> start_async(:prev, fn -> Watch.previous_episode(uuid, title, season, episode) end)
    |> start_async(:episodes, fn -> Watch.episodes(id, season, uuid) end)
  end

  # A direct (non-remuxed) release has no remux id; subtitles written beside it need a stable one.
  defp fallback_id({source, stream}) do
    :crypto.hash(:sha256, "#{source.hash}-#{stream[:filename]}-#{stream[:filesize]}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # ── events ─────────────────────────────────────────────────────────

  # The player reports the playhead every few seconds. Laev does the arithmetic (what was
  # watched, what was skipped, when it counts as finished) exactly as it does for mpv.
  @impl true
  def handle_event("progress", %{"position" => position, "duration" => duration} = params, socket) do
    %{uuid: uuid, ctx: ctx} = socket.assigns

    if uuid && ctx && is_number(position) do
      case Watch.record_progress(uuid, ctx, position, duration || 0, params["paused"] == true) do
        {:finished, true} -> {:noreply, assign(socket, :up_next, next_episode(socket.assigns))}
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # The player's "Next": the next episode's sources are found and the best (the same release, if it
  # has it) starts — one click, no page in between.
  # The OpenSubtitles choices for one language, listed on request from the subtitles menu.
  def handle_event("os_search", %{"lang" => lang}, %{assigns: %{ctx: ctx, uuid: uuid}} = socket)
      when is_binary(lang) and byte_size(lang) in 2..3 and ctx != nil do
    reply =
      case Watch.os_search(uuid, ctx, lang) do
        {:ok, results} -> %{results: results}
        {:error, why} -> %{error: why}
      end

    {:reply, reply, socket}
  end

  def handle_event("os_pick", %{"id" => id, "lang" => lang} = params, socket) do
    %{uuid: uuid, player: player} = socket.assigns

    case Watch.os_fetch(uuid, player.key, id, lang, params["release"], player.media) do
      {:ok, track} ->
        player = %{player | tracks: Enum.uniq_by(player.tracks ++ [track], & &1.url)}
        {:reply, %{track: track}, assign(socket, :player, player)}

      {:error, why} ->
        {:reply, %{error: why}, socket}
    end
  end

  # A pick from the player's episode menu.
  def handle_event(
        "goto",
        %{"episode" => n},
        %{assigns: %{type: "tv", id: id, season: s}} = socket
      )
      when is_integer(n) do
    query =
      case socket.assigns.current do
        {source, _} -> [prefer: source.hash]
        _ -> []
      end

    {:noreply,
     push_navigate(socket,
       to: ~p"/watch/tv/#{id}/#{s}/#{n}?#{query ++ study_q(socket)}",
       replace: true
     )}
  end

  # A pick from the audio menu: this title in that language from now on (a study session for it),
  # the subtitle language as it is for this page. The same episode, found again.
  def handle_event("audio_lang", %{"lang" => lang}, %{assigns: %{uuid: uuid}} = socket)
      when is_binary(lang) and not is_nil(uuid) do
    %{type: type, id: id} = socket.assigns

    subs =
      case socket.assigns.study do
        %{"subs" => subs} -> subs
        _ -> Watch.preferred_subs(uuid) || "off"
      end

    Roki.Study.put(uuid, type, id, lang, subs)

    path =
      if type == "movie",
        do: ~p"/watch/movie/#{id}?#{[study: 1]}",
        else: ~p"/watch/tv/#{id}/#{socket.assigns.season}/#{socket.assigns.episode}?#{[study: 1]}"

    {:noreply, push_navigate(socket, to: path, replace: true)}
  end

  def handle_event("next", _params, %{assigns: %{up_next: {s, e}, id: id}} = socket) do
    query =
      case socket.assigns.current do
        {source, _} -> [prefer: source.hash]
        _ -> []
      end

    {:noreply,
     push_navigate(socket,
       to: ~p"/watch/tv/#{id}/#{s}/#{e}?#{query ++ study_q(socket)}",
       replace: true
     )}
  end

  def handle_event("next", _params, socket), do: {:noreply, socket}

  def handle_event("previous", _params, %{assigns: %{up_prev: {s, e, _tag}, id: id}} = socket) do
    query =
      case socket.assigns.current do
        {source, _} -> [prefer: source.hash]
        _ -> []
      end

    {:noreply,
     push_navigate(socket,
       to: ~p"/watch/tv/#{id}/#{s}/#{e}?#{query ++ study_q(socket)}",
       replace: true
     )}
  end

  def handle_event("previous", _params, socket), do: {:noreply, socket}

  def handle_event("ended", _params, socket) do
    %{uuid: uuid, ctx: ctx} = socket.assigns
    if uuid && ctx, do: Task.start(fn -> Watch.ended(uuid, ctx) end)

    next = socket.assigns.up_next || next_episode(socket.assigns)

    with {season, episode} <- next,
         true <- socket.assigns.uuid && Watch.autoplay?(socket.assigns.uuid) do
      query =
        case socket.assigns.current do
          {source, _} -> [prefer: source.hash]
          _ -> []
        end

      {:noreply,
       push_navigate(socket,
         to: ~p"/watch/tv/#{socket.assigns.id}/#{season}/#{episode}?#{query ++ study_q(socket)}"
       )}
    else
      _ -> {:noreply, assign(socket, :up_next, next)}
    end
  end

  defp next_episode(%{type: "tv", title: title, season: season, episode: episode, episodes: eps})
       when is_integer(episode) and title != nil do
    nexts = if is_list(eps), do: Enum.filter(eps, &(&1.number > episode and &1.aired?)), else: []

    cond do
      nexts != [] -> {season, hd(nexts).number}
      Enum.any?(title.seasons, &(&1.number == season + 1)) -> {season + 1, 1}
      true -> nil
    end
  end

  defp next_episode(_), do: nil

  # A little way into an episode, the one after it is looked for, so it starts at once.
  @impl true
  def handle_info(
        :warm_next,
        %{assigns: %{up_next: {s, e}, title: %{} = title, uuid: uuid}} = socket
      ) do
    Roki.Watch.Prefetch.warm(uuid, title, s, e)
    {:noreply, socket}
  end

  def handle_info(:warm_next, socket), do: {:noreply, socket}

  def handle_info({:status, token, text}, %{assigns: %{token: token}} = socket),
    do: {:noreply, assign(socket, status: text, probe: nil)}

  def handle_info({:probe, token, done, ok, total}, %{assigns: %{token: token}} = socket),
    do: {:noreply, assign(socket, probe: %{done: done, ok: ok, total: total})}

  def handle_info({:candidates, token, list}, %{assigns: %{token: token}} = socket),
    do: {:noreply, update(socket, :checks, &Roki.Watch.Checks.add(&1, list))}

  def handle_info({:checked, token, hash, state}, %{assigns: %{token: token}} = socket),
    do: {:noreply, update(socket, :checks, &Roki.Watch.Checks.mark(&1, hash, state))}

  def handle_info(_stale, socket), do: {:noreply, socket}

  # ── view ───────────────────────────────────────────────────────────

  # Study mode goes on in the next episode's address, and on a renamed one.
  defp study_q(%{assigns: assigns}), do: study_q(assigns)
  defp study_q(%{study: %{}}), do: [study: 1]
  defp study_q(_), do: []

  defp watch_path(%{type: "movie", id: id} = a, hash),
    do: ~p"/watch/movie/#{id}?#{[h: hash] ++ study_q(a)}"

  defp watch_path(%{type: "tv", id: id, season: s, episode: e} = a, hash),
    do: ~p"/watch/tv/#{id}/#{s}/#{e}?#{[h: hash] ++ study_q(a)}"

  defp sources_path(%{type: "movie", id: id}), do: ~p"/sources/movie/#{id}"

  defp sources_path(%{type: "tv", id: id, season: s, episode: e}),
    do: ~p"/sources/tv/#{id}/#{s}/#{e}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/watch"
    >
      <div class="space-y-4">
        <div class="flex flex-wrap items-center gap-3">
          <div class="min-w-0 flex-1">
            <.link
              navigate={sources_path(assigns)}
              class="text-sm text-base-content/60 hover:text-primary"
            >
              ← Sources
            </.link>
            <h1 class="truncate text-xl font-bold tracking-tight sm:text-2xl">
              {if @title, do: @title.title, else: "Loading…"}<span class="text-base-content/50">{now_playing(
                @title || %{type: @type},
                @season,
                @episode
              )}</span>
            </h1>
          </div>
        </div>

        <div :if={@uuid == nil} class="alert text-sm">
          <span>Log in, and connect your debrid account through laev, to watch this.</span>
          <a href="/phoenix_kit/users/log-in" class="btn btn-sm">Log in</a>
        </div>
        <div :if={@uuid != nil and not @linked?} class="alert text-sm">
          <span>Connect laev on your shelf to watch this — your Real-Debrid or TorBox account does the streaming.</span>
          <.link navigate={~p"/"} class="btn btn-sm">Connect laev</.link>
        </div>

        <p :if={@title_error} class="alert alert-error">
          Couldn't load this title just now. Try again in a minute.
        </p>

        <div :if={@failed} class="space-y-3">
          <p class="alert alert-warning text-sm">{@failed}</p>
          <.link navigate={sources_path(assigns)} class="btn">Choose another source</.link>
        </div>

        <div
          :if={@linked? and @player == nil and @failed == nil and @title_error == nil}
          class="space-y-3 rounded-box bg-base-200 p-6 text-sm"
          aria-busy="true"
        >
          <div class="flex items-center gap-3">
            <span class="loading loading-spinner loading-sm"></span>
            <span>{if @probe, do: "Checking releases", else: @status}</span>
            <span :if={@probe} class="text-base-content/60">{@probe.done}/{@probe.total}</span>
          </div>
          <progress
            class="progress progress-primary w-full"
            value={if @probe && @probe.total > 0, do: @probe.done}
            max={if @probe && @probe.total > 0, do: @probe.total}
          ></progress>
          <.checks_list checks={@checks} />
        </div>
      </div>
    </Layouts.app>

    <%!-- Once there is something to play, the player is the page: the whole screen, nothing to scroll. --%>
    <.study_player
      :if={@player}
      player={@player}
      progress?={true}
      immersive?={true}
      study?={@study != nil}
      episodes={if is_list(@episodes), do: @episodes, else: []}
      current={@episode}
      label={if @title, do: @title.title <> now_playing(@title, @season, @episode)}
      home={if @title, do: ~p"/title/#{@type}/#{@id}", else: ~p"/home"}
    />
    <style :if={@player}>
      html, body { overflow: hidden; height: 100%; overscroll-behavior: none; }
    </style>
    """
  end
end
