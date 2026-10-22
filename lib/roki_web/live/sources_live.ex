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
          ctx: nil,
          playable: [],
          rest: [],
          cap: nil,
          key: nil,
          cached_at: nil,
          good: nil,
          current: nil,
          external: nil,
          auto: :off,
          auto_req: false,
          failed: nil,
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

  defp platform_param(socket) do
    params = if connected?(socket), do: get_connect_params(socket) || %{}, else: %{}

    case params["platform"] do
      p when p in ["ios", "android"] -> String.to_existing_atom(p)
      _ -> :desktop
    end
  end

  # Play arrives with `?auto=1`: the best source starts by itself (this once — the address is
  # cleaned straight away, so coming back here with the back button, or reloading, only lists).
  @impl true
  def handle_params(%{"auto" => "1"}, _uri, socket) do
    if connected?(socket),
      do:
        {:noreply,
         socket
         |> assign(:auto_req, true)
         |> push_patch(to: clean_path(socket.assigns), replace: true)},
      else: {:noreply, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

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
    parent = self()

    socket
    |> cancel_async(:pipeline)
    |> assign(
      token: token,
      phase: :working,
      status: "Starting…",
      probe: nil,
      playable: [],
      rest: [],
      current: nil,
      external: nil,
      failed: nil,
      cached_at: nil
    )
    |> start_async(:pipeline, fn ->
      Resolver.run(parent, token, uuid, title, season, episode, force?, mode)
    end)
  end

  @impl true
  def handle_async(:title, {:ok, {:ok, title, auto?}}, socket) do
    socket =
      assign(socket,
        title: title,
        page_title: title.title,
        auto: if(auto? and socket.assigns.auto_req, do: :pending, else: :off)
      )

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
      do: {:noreply, assign(socket, phase: :failed, failed: Resolver.failure(reason), auto: :off)}

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
      case Resolver.pick(res.playable, res.cap, res.good, socket.assigns.mode) do
        {:play, pair} -> socket |> assign(auto: :done) |> start(pair)
        _ -> assign(socket, auto: :off)
      end
    else
      socket
    end
  end

  # The browser plays on its own page; an external player is opened from here.
  defp start(%{assigns: %{mode: :browser}} = socket, {source, _stream}),
    do: push_navigate(socket, to: watch_path(socket.assigns, source.hash))

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

    {:noreply,
     socket
     |> assign(busy?: true, phase: :working, status: "Checking more releases…")
     |> start_async(:more, fn ->
       Resolver.more(parent, token, uuid, ctx, rest, have, key, hours)
     end)}
  end

  def handle_event("more", _params, socket), do: {:noreply, socket}

  # Look again, ignoring the cached releases; nothing starts by itself this time.
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

  def handle_event("mark_watched", _params, socket) do
    %{uuid: uuid, ctx: ctx} = socket.assigns
    if uuid && ctx, do: Watch.mark_watched(uuid, ctx)
    {:noreply, socket}
  end

  defp new_cap(%{assigns: %{ctx: nil, cap: cap}}, _mode), do: cap

  defp new_cap(%{assigns: %{uuid: uuid, ctx: ctx}}, mode),
    do: Watch.ceiling(uuid, ctx, mode, Roki.Laev.web_settings(uuid))

  defp limit(:browser, uuid),
    do: Roki.Laev.web_settings(uuid)["browser_max_resolution"] || "1080p"

  defp limit(:external, _uuid), do: nil

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
        <div>
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
        <p :if={@phase == :failed} class="alert alert-warning text-sm">{@failed}</p>
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
        />

        <.sources
          :if={@playable != []}
          playable={@playable}
          rest={@rest}
          current={@current}
          mode={@mode}
          busy={@busy?}
          limit={limit(@mode, @uuid)}
        />
      </div>

      <.auto_start
        :if={@linked? and @auto == :pending and @phase in [:loading, :working] and @external == nil}
        probe={@probe}
        what={if @title, do: @title.title <> now_playing(@title, @season, @episode)}
      />
    </Layouts.app>
    """
  end

  defp back_path("movie", id), do: ~p"/title/movie/#{id}"
  defp back_path("tv", id), do: ~p"/title/tv/#{id}/episodes"
end
