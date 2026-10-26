defmodule RokiWeb.SourcesLive do
  @moduledoc """
  `/sources/movie/:id` and `/sources/tv/:id/:season/:episode` — the releases for what you pressed
  Play on.

  While they are searched and checked a pop-up says the best one will start by itself (a bar
  shows how far it is; Cancel, a click outside it or Escape leaves you to choose). When it is
  found, on the browser it opens the player page (`WatchLive`); on an external player it opens
  the app and keeps you here. With the pop-up cancelled — or the setting off — the releases are
  listed to pick from, with Load more for the rest.
  """
  use RokiWeb, :live_view

  import RokiWeb.WatchComponents

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
          page_title: "Sources",
          type: type,
          id: n,
          season: season,
          episode: episode,
          uuid: uuid,
          linked?: uuid != nil and Roki.Laev.connected?(uuid),
          mode: mode_param(socket),
          platform: platform_param(socket),
          title: nil,
          title_error: nil,
          token: 0,
          phase: :loading,
          status: "Starting…",
          probe: nil,
          checks: [],
          starting: nil,
          start_error: nil,
          ctx: nil,
          playable: [],
          rest: [],
          cap: nil,
          key: nil,
          cached_at: nil,
          good: nil,
          current: nil,
          external: nil,
          next: nil,
          prev: nil,
          prefer: nil,
          auto: :off,
          auto_req: false,
          failed: nil,
          failed_reason: nil,
          heavy_ok: false,
          heavy_allowed?: uuid != nil and Roki.Keys.heavy?(uuid),
          caps: caps_param(socket),
          busy?: false
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

  defp mode_param(socket) do
    params = if connected?(socket), do: get_connect_params(socket) || %{}, else: %{}

    if params["player"] == "browser", do: :browser, else: :external
  end

  # What this browser said it decodes itself, sent with the connection (see app.js).
  defp caps_param(socket) do
    params = if connected?(socket), do: get_connect_params(socket) || %{}, else: %{}
    Roki.Direct.caps(params["caps"])
  end

  defp platform_param(socket) do
    params = if connected?(socket), do: get_connect_params(socket) || %{}, else: %{}

    case params["platform"] do
      p when p in ["ios", "android", "mac"] -> String.to_existing_atom(p)
      _ -> :desktop
    end
  end

  # Play arrives with `?auto=1`: the best source starts by itself (this once — the address is
  # cleaned straight away, so coming back here with the back button, or reloading, only lists).
  @impl true
  def handle_params(params, _uri, socket) do
    # `prefer` is the release the last episode played from: a season pack has the next one too, so
    # the same release goes on without a new choice. A hint only — the best is used if it is gone.
    socket =
      if params["prefer"] in [nil, ""],
        do: socket,
        else: assign(socket, :prefer, String.slice(params["prefer"], 0, 64))

    cond do
      # Playing in the browser, the sources page has nothing to add: the watch page finds the
      # release and starts it itself. Going straight there saves a whole page.
      auto?(params, socket) and socket.assigns.linked? and socket.assigns.mode == :browser ->
        {:noreply, push_navigate(socket, to: direct_watch_path(socket.assigns), replace: true)}

      true ->
        auto_or_list(params, socket)
    end
  end

  # `?auto=1` asks once, for the page that was opened with it. A page that rejoins (the phone
  # woke up, the connection dropped — coming back from the external player does exactly this)
  # joins with the address it first loaded, which still has `auto=1`; LiveView counts the joins
  # (`_mounts`), so only the first one starts anything.
  defp auto?(params, socket) do
    params["auto"] == "1" and connected?(socket) and
      Map.get(get_connect_params(socket) || %{}, "_mounts", 0) == 0
  end

  defp direct_watch_path(%{type: "movie", id: id, prefer: prefer}),
    do: ~p"/watch/movie/#{id}?#{prefer_query(prefer)}"

  defp direct_watch_path(%{type: "tv", id: id, season: s, episode: e, prefer: prefer}),
    do: ~p"/watch/tv/#{id}/#{s}/#{e}?#{prefer_query(prefer)}"

  defp prefer_query(nil), do: []
  defp prefer_query(hash), do: [prefer: hash]

  defp auto_or_list(params, socket) do
    if auto?(params, socket),
      do:
        {:noreply,
         socket
         |> assign(:auto_req, true)
         |> push_patch(to: clean_path(socket.assigns), replace: true)},
      else: {:noreply, socket}
  end

  defp clean_path(%{type: "movie", id: id}), do: ~p"/sources/movie/#{id}"

  defp clean_path(%{type: "tv", id: id, season: s, episode: e}),
    do: ~p"/sources/tv/#{id}/#{s}/#{e}"

  defp load(socket) do
    %{type: type, id: id, uuid: uuid} = socket.assigns

    start_async(socket, :title, fn ->
      with {:ok, title} <- Watch.title(type, id, uuid), do: {:ok, title, Watch.auto_start?(uuid)}
    end)
  end

  # ── the search ─────────────────────────────────────────────────────

  defp begin(socket, force?) do
    token = socket.assigns.token + 1
    %{uuid: uuid, title: title, season: season, episode: episode, mode: mode} = socket.assigns
    heavy_ok = socket.assigns.heavy_ok
    caps = socket.assigns.caps
    parent = self()

    socket
    |> cancel_async(:pipeline)
    |> assign(
      token: token,
      phase: :working,
      status: "Starting…",
      probe: nil,
      checks: [],
      start_error: nil,
      playable: [],
      rest: [],
      current: nil,
      external: nil,
      failed: nil,
      failed_reason: nil,
      cached_at: nil
    )
    |> start_async(:pipeline, fn ->
      Resolver.run(
        parent,
        token,
        uuid,
        title,
        season,
        episode,
        force?,
        mode,
        false,
        heavy_ok,
        caps
      )
    end)
  end

  @impl true
  def handle_async(:title, {:ok, {:ok, title, auto?}}, socket) do
    %{uuid: uuid, season: season, episode: episode} = socket.assigns
    title = Map.put(title, :tag, Watch.episode_tag(uuid, title, season, episode))

    %{uuid: uuid, season: season, episode: episode} = socket.assigns

    socket =
      assign(socket,
        title: title,
        page_title: title.title,
        auto: if(auto? and socket.assigns.auto_req, do: :pending, else: :off)
      )

    socket =
      if socket.assigns.type == "tv",
        do:
          socket
          |> start_async(:next, fn -> Watch.next_episode(uuid, title, season, episode) end)
          |> start_async(:prev, fn -> Watch.previous_episode(uuid, title, season, episode) end),
        else: socket

    {:noreply, begin(socket, false)}
  end

  def handle_async(:title, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :title_error, reason || true)}

  def handle_async(:title, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :title_error, reason)}

  def handle_async(
        :pipeline,
        {:ok, {:ok, %{token: token} = res}},
        %{assigns: %{token: token}} = socket
      ),
      do: {:noreply, found(socket, res)}

  def handle_async(
        :pipeline,
        {:ok, {:error, token, reason}},
        %{assigns: %{token: token}} = socket
      ),
      do:
        {:noreply,
         assign(socket,
           phase: :failed,
           failed: Resolver.failure(reason),
           failed_reason: reason,
           auto: :off
         )}

  def handle_async(:pipeline, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket,
         phase: :failed,
         failed: "Something went wrong (#{inspect(reason, limit: 3)}).",
         auto: :off
       )}

  def handle_async(:pipeline, _stale, socket), do: {:noreply, socket}

  def handle_async(
        :more,
        {:ok, {:ok, token, playable, rest}},
        %{assigns: %{token: token}} = socket
      ),
      do: {:noreply, assign(socket, playable: playable, rest: rest, phase: :ready, busy?: false)}

  def handle_async(:prestart, {:ok, {source, {:ok, _player}}}, socket),
    do: {:noreply, push_navigate(socket, to: watch_path(socket.assigns, source.hash))}

  def handle_async(:prestart, {:ok, {_source, {:error, reason}}}, socket) do
    {:noreply, assign(socket, starting: nil, current: nil, start_error: Resolver.failure(reason))}
  end

  def handle_async(:prestart, _other, socket),
    do:
      {:noreply,
       assign(socket,
         starting: nil,
         current: nil,
         start_error: "That one would not start. Pick another."
       )}

  def handle_async(:next, {:ok, {_s, _e, _tag} = next}, socket),
    do: {:noreply, assign(socket, :next, next)}

  def handle_async(:next, _other, socket), do: {:noreply, socket}

  def handle_async(:prev, {:ok, {_s, _e, _tag} = prev}, socket),
    do: {:noreply, assign(socket, :prev, prev)}

  def handle_async(:prev, _other, socket), do: {:noreply, socket}

  def handle_async(:more, _other, socket),
    do: {:noreply, assign(socket, phase: :ready, busy?: false)}

  # The releases are known. Nobody has chosen yet: start the best on its own unless the pop-up was
  # cancelled (or the setting is off), in which case they are listed.
  defp found(socket, res) do
    socket =
      assign(socket,
        phase: :ready,
        ctx: res.ctx,
        playable: res.playable,
        rest: res.rest,
        cap: res.cap,
        key: res.key,
        cached_at: res.cached_at,
        good: res.good
      )

    if socket.assigns.auto == :pending do
      case preferred(socket, res) ||
             Resolver.pick(res.playable, res.cap, res.good, socket.assigns.mode, socket.assigns.caps) do
        {:play, pair} -> socket |> assign(auto: :done) |> start(pair)
        # A release that was kept from the last episode: a {source, stream} pair as it is.
        {%{} = _source, %{} = _stream} = pair -> socket |> assign(auto: :done) |> start(pair)
        # Nothing to pick without asking (`{:ask, why}`): the releases are listed to choose from.
        _ -> assign(socket, auto: :off)
      end
    else
      socket
    end
  end

  # The release the previous episode used, when it is among these and fits what the player takes.
  defp preferred(%{assigns: %{prefer: hash}}, res) when is_binary(hash) do
    case Resolver.find(res.playable, hash) do
      {source, _} = pair ->
        if Laev.Sources.resolution_at_most?(source.resolution, res.cap), do: pair

      _ ->
        nil
    end
  end

  defp preferred(_socket, _res), do: nil

  # The browser plays on its own page; an external player is opened from here.
  # The browser's player is prepared *here*, before its page opens — so the page opens on a video
  # that is already running instead of starting it, which was a second wait after the first.
  defp start(%{assigns: %{mode: :browser}} = socket, {source, stream} = pair) do
    %{uuid: uuid, ctx: ctx, caps: caps} = socket.assigns

    socket
    |> assign(starting: %{name: source.name}, current: pair, start_error: nil, auto: :done)
    |> start_async(:prestart, fn -> {source, Watch.start(uuid, ctx, source, stream, caps)} end)
  end

  defp start(socket, pair), do: hand_over(socket, pair)

  defp hand_over(socket, {source, stream} = pair) do
    %{uuid: uuid, ctx: ctx, key: key, title: title, platform: platform} = socket.assigns
    app = Roki.Laev.web_settings(uuid)["external_app"]
    external = Watch.external(uuid, ctx, source, stream)
    if key, do: SourceCache.mark_good(uuid, key, source.hash)

    launch = launch_url(app, platform, external.url, external.filename || title.title)

    socket
    |> assign(current: pair, external: Map.merge(external, %{app: app, launch: launch}))
    |> then(&if(launch, do: push_event(&1, "roki:launch", %{url: launch}), else: &1))
  end

  defp watch_path(%{type: "movie", id: id}, hash), do: ~p"/watch/movie/#{id}?#{[h: hash]}"

  defp watch_path(%{type: "tv", id: id, season: s, episode: e}, hash),
    do: ~p"/watch/tv/#{id}/#{s}/#{e}?#{[h: hash]}"

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("cancel_auto", _params, %{assigns: %{auto: :pending}} = socket),
    do: {:noreply, assign(socket, :auto, :cancelled)}

  def handle_event("cancel_auto", _params, socket), do: {:noreply, socket}

  def handle_event("choose", %{"idx" => idx} = params, socket) do
    case Enum.at(socket.assigns.playable, to_int(idx) || -1) do
      nil ->
        {:noreply, socket}

      {source, _stream} = pair ->
        Watch.remember_resolution(socket.assigns.uuid, socket.assigns.ctx, source)

        if socket.assigns.mode == :external or params["via"] == "external",
          do: {:noreply, hand_over(assign(socket, :auto, :done), pair)},
          else: {:noreply, push_navigate(socket, to: watch_path(socket.assigns, source.hash))}
    end
  end

  def handle_event("more", _params, %{assigns: %{rest: [_ | _]}} = socket) do
    %{rest: rest, uuid: uuid, ctx: ctx, token: token, playable: have, key: key} = socket.assigns
    parent = self()
    hours = SourceCache.hours(Roki.Laev.web_settings(uuid))
    light? = Resolver.light?(socket.assigns.mode, uuid, socket.assigns.heavy_ok)
    caps = socket.assigns.caps

    {:noreply,
     socket
     |> assign(busy?: true, phase: :working, status: "Checking more releases…")
     |> start_async(:more, fn ->
       Resolver.more(parent, token, uuid, ctx, rest, have, key, hours, light?, caps)
     end)}
  end

  def handle_event("more", _params, socket), do: {:noreply, socket}

  # Look again, ignoring the cached releases; nothing starts by itself this time.
  # A heavy-allowed account says yes to re-encoded releases for this search only.
  def handle_event("search_heavy", _params, %{assigns: %{uuid: uuid}} = socket) do
    if Roki.Keys.heavy?(uuid),
      do: {:noreply, socket |> assign(heavy_ok: true, auto: :cancelled) |> begin(false)},
      else: {:noreply, socket}
  end

  def handle_event("retry", _params, socket),
    do: {:noreply, socket |> assign(:auto, :cancelled) |> begin(true)}

  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ["browser", "external"] do
    mode = String.to_existing_atom(mode)

    # The page follows the player: the list is the releases that player can take (a browser:
    # up to its cap; an external player: all, 4K included), and an opened external player's
    # panel goes when the browser is chosen.
    {:noreply,
     socket
     |> assign(mode: mode, cap: new_cap(socket, mode))
     |> then(&if(mode == :browser, do: assign(&1, external: nil, current: nil), else: &1))
     |> push_event("roki:player", %{mode: Atom.to_string(mode)})}
  end

  # One click to the next episode, from here: its sources, the same release if it is there, and the
  # best one starts by itself. Going on from an external player means this one was watched — the
  # player cannot say so itself — so it is marked.
  def handle_event("next", _params, %{assigns: %{next: {s, e, _tag}}} = socket) do
    %{uuid: uuid, ctx: ctx, external: external, current: current, id: id} = socket.assigns
    if external && uuid && ctx, do: Watch.mark_watched(uuid, ctx)

    query =
      case current do
        {source, _} -> [auto: 1, prefer: source.hash]
        _ -> [auto: 1]
      end

    {:noreply, push_navigate(socket, to: ~p"/sources/tv/#{id}/#{s}/#{e}?#{query}")}
  end

  def handle_event("next", _params, socket), do: {:noreply, socket}

  # The one before: its sources, the same way (nothing is marked — going back is not finishing).
  def handle_event("previous", _params, %{assigns: %{prev: {s, e, _tag}, id: id}} = socket) do
    query =
      case socket.assigns.current do
        {source, _} -> [auto: 1, prefer: source.hash]
        _ -> [auto: 1]
      end

    {:noreply, push_navigate(socket, to: ~p"/sources/tv/#{id}/#{s}/#{e}?#{query}")}
  end

  def handle_event("previous", _params, socket), do: {:noreply, socket}

  def handle_event("mark_watched", _params, socket) do
    %{uuid: uuid, ctx: ctx} = socket.assigns
    if uuid && ctx, do: Watch.mark_watched(uuid, ctx)
    {:noreply, socket}
  end

  defp new_cap(%{assigns: %{ctx: nil, cap: cap}}, _mode), do: cap

  defp new_cap(%{assigns: %{uuid: uuid, ctx: ctx, caps: caps}}, mode),
    do: Watch.ceiling(uuid, ctx, mode, Roki.Laev.web_settings(uuid), caps)

  defp limit(:browser, uuid, caps), do: Watch.browser_limit(Roki.Laev.web_settings(uuid), caps)
  defp limit(:external, _uuid, _caps), do: nil

  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @impl true
  def handle_info({:status, token, text}, %{assigns: %{token: token}} = socket),
    do: {:noreply, assign(socket, status: text)}

  def handle_info({:probe, token, done, ok, total}, %{assigns: %{token: token}} = socket),
    do: {:noreply, assign(socket, probe: %{done: done, ok: ok, total: total})}

  def handle_info({:candidates, token, list}, %{assigns: %{token: token}} = socket),
    do: {:noreply, update(socket, :checks, &Roki.Watch.Checks.add(&1, list))}

  def handle_info({:checked, token, hash, state}, %{assigns: %{token: token}} = socket),
    do: {:noreply, update(socket, :checks, &Roki.Watch.Checks.mark(&1, hash, state))}

  def handle_info(_stale, socket), do: {:noreply, socket}

  # ── view ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/sources"
    >
      <div class="space-y-6">
        <div class="flex flex-wrap items-end gap-3">
          <div class="min-w-0 flex-1">
            <.link
              navigate={back_path(@type, @id)}
              class="text-sm text-base-content/60 hover:text-primary"
            >
              ← {if @title, do: @title.title, else: "Back"}
            </.link>
            <h1 class="mt-1 text-2xl font-bold tracking-tight sm:text-3xl">
              Sources<span class="text-base-content/50">{now_playing(
                @title || %{type: @type},
                @season,
                @episode
              )}</span>
            </h1>
          </div>
          <div :if={(@next || @prev) && @external == nil} class="flex gap-2">
            <button
              :if={@prev}
              phx-click="previous"
              class="btn btn-sm gap-1.5"
              title="The episode before"
            >
              <.icon name="hero-backward" class="h-4 w-4" />
              <span class="hidden sm:inline">Previous ·</span> {elem(@prev, 2)}
            </button>
            <button :if={@next} phx-click="next" class="btn btn-sm gap-1.5" title="The next episode">
              <span class="hidden sm:inline">Next ·</span> {elem(@next, 2)}
              <.icon name="hero-forward" class="h-4 w-4" />
            </button>
          </div>
        </div>

        <div :if={@uuid == nil} class="alert text-sm">
          <span>Log in, and connect your debrid account through laev, to watch here.</span>
          <a href="/phoenix_kit/users/log-in" class="btn btn-sm">Log in</a>
        </div>
        <div :if={@uuid != nil and not @linked?} class="alert text-sm">
          <span>Connect laev on your shelf to watch here — your Real-Debrid or TorBox account does the streaming.</span>
          <.link navigate={~p"/"} class="btn btn-sm">Connect laev</.link>
        </div>

        <p :if={@title_error} class="alert alert-error">
          Couldn't load this title just now. Try again in a minute.
        </p>

        <.cache_note :if={@cached_at} at={@cached_at} busy={@phase == :working} />

        <.progress_line
          :if={@phase in [:loading, :working] and @auto != :pending}
          probe={@probe}
          text={@status}
        />
        <.checks_list :if={@phase in [:loading, :working] and @auto != :pending} checks={@checks} />
        <p :if={@start_error} class="alert alert-warning text-sm">{@start_error}</p>
        <p :if={@phase == :failed} class="alert alert-warning text-sm">{@failed}</p>
        <.heavy_offer :if={
          @phase == :failed and @failed_reason == :no_light and @mode == :browser and
            @heavy_allowed?
        } />
        <p
          :if={@phase == :ready and @playable != [] and @external == nil and @auto != :pending}
          class="text-sm text-base-content/70"
        >
          Pick a release.
        </p>

        <.external_panel
          :if={@external}
          external={@external}
          platform={@platform}
          title={@title}
          season={@season}
          episode={@episode}
          next={@next}
          prev={@prev}
        />

        <.sources
          :if={@playable != []}
          playable={@playable}
          caps={@caps}
          rest={@rest}
          current={@current}
          mode={@mode}
          busy={@busy?}
          limit={limit(@mode, @uuid, @caps)}
        />
      </div>

      <.auto_start
        :if={@linked? and @auto == :pending and @phase in [:loading, :working] and @external == nil}
        probe={@probe}
        checks={@checks}
        what={if @title, do: @title.title <> now_playing(@title, @season, @episode)}
      />

      <.starting :if={@starting} name={@starting.name} />
    </Layouts.app>
    """
  end

  defp back_path("movie", id), do: ~p"/title/movie/#{id}"
  defp back_path("tv", id), do: ~p"/title/tv/#{id}/episodes"
end
