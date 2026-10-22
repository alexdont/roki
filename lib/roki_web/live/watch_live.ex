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
  import RokiWeb.WatchComponents, only: [now_playing: 3]

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Watch
  alias Roki.Watch.{Resolver, SourceCache}

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    type = if params["season"], do: "tv", else: "movie"

    with {n, ""} <- Integer.parse(id),
         {season, episode} <- parse_episode(params) do
      scope = socket.assigns[:phoenix_kit_current_scope]
      uuid = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)

      socket =
        assign(socket,
          page_title: "Watch",
          type: type,
          id: n,
          season: season,
          episode: episode,
          hash: nil,
          uuid: uuid,
          linked?: uuid != nil and Roki.Laev.connected?(uuid),
          title: nil,
          title_error: nil,
          token: 0,
          status: "Starting…",
          probe: nil,
          ctx: nil,
          key: nil,
          current: nil,
          player: nil,
          failed: nil,
          episodes: nil,
          up_next: nil
        )

      {:ok, if(connected?(socket) and socket.assigns.linked?, do: load(socket), else: socket)}
    else
      _ -> {:ok, push_navigate(socket, to: ~p"/home")}
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
    {:noreply, assign(socket, :hash, hash)}
  end

  defp load(socket) do
    %{type: type, id: id, uuid: uuid} = socket.assigns
    start_async(socket, :title, fn -> Watch.title(type, id, uuid) end)
  end

  # The title is known: find the release, start it, and (for a series) fetch the season's
  # episodes so the next one is known.
  defp resolve(socket) do
    token = socket.assigns.token + 1
    %{uuid: uuid, title: title, season: season, episode: episode, hash: hash} = socket.assigns
    parent = self()

    socket
    |> assign(token: token, failed: nil, player: nil)
    |> start_async(:resolve, fn ->
      with {:ok, res} <-
             Resolver.run(parent, token, uuid, title, season, episode, false, :browser),
           {res, pair} <- locate(parent, token, uuid, res, hash, 3),
           {:ok, pair} <- choose(res, pair),
           {:ok, player} <- start(uuid, res.ctx, pair) do
        {:ok, token, res, pair, player}
      else
        {:error, ^token, reason} -> {:error, token, reason}
        {:error, reason} -> {:error, token, reason}
      end
    end)
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

    data = %{
      url: player.url,
      hls: player.hls?,
      resume: player.resume_at,
      tracks: player.subtitles,
      prefer: prefer,
      key: play_id
    }

    if res.key, do: SourceCache.mark_good(uuid, res.key, source.hash)

    socket =
      socket
      |> assign(player: data, current: pair, ctx: res.ctx, key: res.key)
      |> name_the_release(source.hash)

    # What the release did not carry: their language, and for anime the original Japanese
    # (Jimaku), each fetched on its own so a slow provider holds up nothing.
    socket =
      for lang <- Watch.external_langs(uuid, res.ctx, player.subtitles), reduce: socket do
        acc ->
          start_async(acc, {:ext_subs, lang}, fn ->
            {token, Watch.external_subtitle(uuid, res.ctx, play_id, lang)}
          end)
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
      do: {:noreply, assign(socket, :player, %{player | tracks: player.tracks ++ [track]})}

  def handle_async({:ext_subs, _lang}, _other, socket), do: {:noreply, socket}

  def handle_async(:episodes, {:ok, {:ok, eps}}, socket),
    do: {:noreply, assign(socket, :episodes, eps)}

  def handle_async(:episodes, _other, socket), do: {:noreply, socket}

  # The address names the release that is playing, so a reload — or a copy of it — plays the same.
  defp name_the_release(%{assigns: %{hash: nil}} = socket, hash),
    do: push_patch(socket, to: watch_path(socket.assigns, hash), replace: true)

  defp name_the_release(socket, _hash), do: socket

  defp load_episodes(socket) do
    %{id: id, season: season, uuid: uuid} = socket.assigns
    start_async(socket, :episodes, fn -> Watch.episodes(id, season, uuid) end)
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

  def handle_event("ended", _params, socket) do
    next = socket.assigns.up_next || next_episode(socket.assigns)

    with {season, episode} <- next,
         true <- socket.assigns.uuid && Watch.autoplay?(socket.assigns.uuid) do
      {:noreply,
       push_navigate(socket, to: ~p"/watch/tv/#{socket.assigns.id}/#{season}/#{episode}")}
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

  @impl true
  def handle_info({:status, token, text}, %{assigns: %{token: token}} = socket),
    do: {:noreply, assign(socket, status: text)}

  def handle_info({:probe, token, done, ok, total}, %{assigns: %{token: token}} = socket),
    do: {:noreply, assign(socket, probe: %{done: done, ok: ok, total: total})}

  def handle_info(_stale, socket), do: {:noreply, socket}

  # ── view ───────────────────────────────────────────────────────────

  defp watch_path(%{type: "movie", id: id}, hash), do: ~p"/watch/movie/#{id}?#{[h: hash]}"

  defp watch_path(%{type: "tv", id: id, season: s, episode: e}, hash),
    do: ~p"/watch/tv/#{id}/#{s}/#{e}?#{[h: hash]}"

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
          <.link
            :if={@up_next}
            navigate={next_path(assigns)}
            class="btn btn-primary btn-sm"
          >
            Next episode →
          </.link>
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
        </div>

        <.study_player :if={@player} player={@player} progress?={true} />
      </div>
    </Layouts.app>
    """
  end

  defp next_path(%{id: id, up_next: {s, e}}), do: ~p"/watch/tv/#{id}/#{s}/#{e}"
end
