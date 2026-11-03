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
      avail = Roki.Sources.available(uuid)
      settings = settings_path(scope)
      source = initial_source(uuid, params, avail)

      socket =
        assign(socket,
          page_title: "Sources",
          source: source,
          avail: avail,
          settings: settings,
          setup_msg: nil,
          setup_busy: false,
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
          # Nothing connected for this kind of source: nothing is searched (see `connect_sources/1`).
          phase: if(avail[source] || source in [:pengu, :nuvio], do: :loading, else: :idle),
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
          busy?: false,
          pengu: nil,
          nuvio: nil
        )

      {:ok,
       if(connected?(socket) and uuid != nil,
         do: load(socket),
         else: socket
       )}
    else
      _ -> {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  # Where the page looks first: `?src=` when the link says (the player's "change source" does), else
  # the account's "Play from" setting — but a kind nothing is connected for gives way to the other
  # one when that works.
  defp initial_source(uuid, params, avail) do
    case params["src"] do
      "pengu" -> Roki.Sources.pick(:pengu, avail)
      "nuvio" -> Roki.Sources.pick(:nuvio, avail)
      "torrent" -> Roki.Sources.pick(:torrent, avail)
      _ -> Roki.Sources.current(uuid, avail)
    end
  end

  # Where an account adds what is missing: its Settings page.
  defp settings_path(scope) do
    case scope && Scope.user(scope) do
      %{username: name} when is_binary(name) and name != "" -> "/u/#{name}/settings"
      _ -> "/"
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
      auto?(params, socket) and socket.assigns.linked? and socket.assigns.mode == :browser and
        socket.assigns.source == :torrent and socket.assigns.avail.torrent ->
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

  # `src=torrent`: a release is being asked for, whatever the account's "Play from" says.
  defp direct_watch_path(%{type: "movie", id: id, prefer: prefer}),
    do: ~p"/watch/movie/#{id}?#{[src: "torrent"] ++ prefer_query(prefer)}"

  defp direct_watch_path(%{type: "tv", id: id, season: s, episode: e, prefer: prefer}),
    do: ~p"/watch/tv/#{id}/#{s}/#{e}?#{[src: "torrent"] ++ prefer_query(prefer)}"

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

  # A source was just connected: use it now, loading the title first when nothing has yet.
  defp activate(socket, source) do
    socket = assign(socket, source: source, auto: :off, setup_msg: nil, pengu: nil, nuvio: nil)
    socket = assign(socket, :avail, Map.put(socket.assigns.avail, source, true))

    cond do
      socket.assigns.title == nil -> load(socket)
      source == :pengu -> pengu_search(socket)
      source == :nuvio -> nuvio_search(socket)
      true -> begin(socket, false)
    end
  end

  defp pengu_search(%{assigns: %{title: %{imdb_id: imdb}}} = socket) do
    %{uuid: uuid, season: season, episode: episode} = socket.assigns

    socket
    |> assign(:pengu, :loading)
    |> start_async(:pengu, fn -> Roki.Pengu.streams(uuid, imdb, season, episode) end)
  end

  defp pengu_search(socket),
    do: assign(socket, pengu: {:error, Roki.Pengu.message(:no_imdb_id)}, auto: :off)

  defp nuvio_search(socket, force \\ false) do
    %{uuid: uuid, id: id, type: type, season: season, episode: episode} = socket.assigns

    socket
    |> assign(:nuvio, :loading)
    |> start_async(:nuvio, fn ->
      Roki.Nuvio.search(uuid, id, type, season, episode, force: force)
    end)
  end

  defp clean_path(%{type: "movie", id: id}), do: ~p"/sources/movie/#{id}"

  defp clean_path(%{type: "tv", id: id, season: s, episode: e}),
    do: ~p"/sources/tv/#{id}/#{s}/#{e}"

  defp load(socket) do
    %{type: type, id: id, uuid: uuid} = socket.assigns

    linked? = socket.assigns.linked?
    season = socket.assigns.season

    start_async(socket, :title, fn ->
      # An anime is drawn as the season being watched, not as its first (`Roki.SeasonPosters`).
      with {:ok, title} <- Watch.title(type, id, uuid),
           title = Roki.SeasonPosters.for_title(title, season, uuid),
           do: {:ok, title, not linked? or Watch.auto_start?(uuid)}
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
    tag = if socket.assigns.linked?, do: Watch.episode_tag(uuid, title, season, episode)
    title = Map.put(title, :tag, tag)

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

    # With nothing connected for this kind of source there is nothing to search; the connect panel
    # is what the page shows.
    {:noreply,
     cond do
       not socket.assigns.avail[socket.assigns.source] -> socket
       socket.assigns.source == :pengu -> pengu_search(socket)
       socket.assigns.source == :nuvio -> nuvio_search(socket)
       true -> begin(socket, false)
     end}
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
    do:
      {:noreply,
       push_navigate(socket, to: watch_path(socket.assigns, source.hash), replace: true)}

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

  # Play asked for the best stream: go straight to the player with it; the list is only here when
  # nothing suitable came back.
  def handle_async(:pengu, {:ok, {:ok, streams}}, socket) do
    socket = assign(socket, :pengu, {:ok, Roki.Pengu.group(streams), length(streams)})

    with :pending <- socket.assigns.auto,
         %{id: id} <- Roki.Pengu.best(streams, socket.assigns.caps) do
      {:noreply,
       push_navigate(socket, to: pengu_watch(socket.assigns, id) <> "&auto=1", replace: true)}
    else
      _ -> {:noreply, assign(socket, :auto, :off)}
    end
  end

  def handle_async(:debrid, {:ok, :ok}, socket) do
    socket =
      assign(socket,
        setup_busy: false,
        linked?: true,
        avail: %{socket.assigns.avail | torrent: true}
      )

    {:noreply, activate(socket, :torrent)}
  end

  def handle_async(:debrid, {:ok, {:error, text}}, socket),
    do: {:noreply, assign(socket, setup_busy: false, setup_msg: {:error, text})}

  def handle_async(:debrid, _other, socket),
    do:
      {:noreply,
       assign(socket, setup_busy: false, setup_msg: {:error, "That did not work. Try again."})}

  def handle_async(:pengu, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, pengu: {:error, Roki.Pengu.message(reason)}, auto: :off)}

  def handle_async(:pengu, {:exit, _}, socket),
    do: {:noreply, assign(socket, pengu: {:error, Roki.Pengu.message(:timeout)}, auto: :off)}

  def handle_async(:nuvio, {:ok, {:ok, results}}, socket) do
    socket = assign(socket, :nuvio, {:ok, results})

    with :pending <- socket.assigns.auto,
         %{id: id, provider_id: provider_id} <-
           Roki.Nuvio.best(Roki.Nuvio.streams(results), socket.assigns.caps) do
      {:noreply,
       push_navigate(socket,
         to: nuvio_watch(socket.assigns, provider_id, id) <> "&auto=1",
         replace: true
       )}
    else
      _ -> {:noreply, assign(socket, :auto, :off)}
    end
  end

  def handle_async(:nuvio, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, nuvio: {:error, Roki.Nuvio.message(reason)}, auto: :off)}

  def handle_async(:nuvio, {:exit, _}, socket),
    do: {:noreply, assign(socket, nuvio: {:error, Roki.Nuvio.message(:timeout)}, auto: :off)}

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
             Resolver.pick(
               res.playable,
               res.cap,
               res.good,
               socket.assigns.mode,
               socket.assigns.caps
             ) do
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
  # The switch in the bar: look at torrents or at PenguPlay. Each is searched the first time it is
  # shown and kept after that.
  def handle_event("source", %{"to" => to}, socket) when to in ["torrent", "pengu", "nuvio"] do
    source = String.to_existing_atom(to)
    socket = assign(socket, source: source, auto: :off)

    socket =
      cond do
        socket.assigns.title == nil -> socket
        not socket.assigns.avail[source] -> socket
        source == :pengu and socket.assigns.pengu == nil -> pengu_search(socket)
        source == :nuvio and socket.assigns.nuvio == nil -> nuvio_search(socket)
        source == :torrent and socket.assigns.phase in [:loading, :idle] -> begin(socket, false)
        true -> socket
      end

    {:noreply, socket}
  end

  # The paste fields of the "connect a source" panel.
  def handle_event(
        "setup_pengu",
        %{"pengu" => %{"url" => url}},
        %{assigns: %{uuid: uuid}} = socket
      )
      when is_binary(uuid) do
    case Roki.Pengu.save_url(PhoenixKit.Users.Auth.get_user(uuid), url) do
      {:ok, _user} -> {:noreply, activate(socket, :pengu)}
      {:error, text} -> {:noreply, assign(socket, :setup_msg, {:error, text})}
    end
  end

  def handle_event("setup_debrid", %{"debrid" => keys}, %{assigns: %{uuid: uuid}} = socket)
      when is_binary(uuid) do
    keys = Map.take(keys, ~w(RD_TOKEN TORBOX_API_KEY))

    {:noreply,
     socket
     |> assign(setup_busy: true, setup_msg: nil)
     |> start_async(:debrid, fn -> Roki.Laev.save_debrid(uuid, keys) end)}
  end

  def handle_event("pengu", _params, %{assigns: %{title: %{}}} = socket),
    do: {:noreply, pengu_search(socket)}

  def handle_event("pengu", _params, socket), do: {:noreply, socket}

  def handle_event("nuvio", _params, %{assigns: %{title: %{}}} = socket),
    do: {:noreply, nuvio_search(socket, true)}

  def handle_event("nuvio", _params, socket), do: {:noreply, socket}

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
          else:
            {:noreply,
             push_navigate(socket, to: watch_path(socket.assigns, source.hash), replace: true)}
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
      socket={@socket}
      flash={@flash}
      flush
      bleed
      overlay
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/sources"
    >
      <%!-- The top, as on the other pages: the title's picture under the floating header, which title
            and which episode this is about, and the way back. --%>
      <section class="relative z-20 flex min-h-[clamp(18rem,40svh,26rem)] flex-col justify-end text-white">
        <div class="absolute inset-0 -z-10 overflow-hidden bg-neutral-900">
          <img
            :if={@title && @title[:backdrop]}
            src={Roki.Images.local(@title.backdrop)}
            alt=""
            class="h-full w-full object-cover opacity-70"
          />
          <div class="absolute inset-0 bg-gradient-to-r from-black/85 via-black/50 to-black/10"></div>
          <div class="absolute inset-0 bg-gradient-to-t from-black/80 via-transparent to-black/50">
          </div>
        </div>

        <div class="flex flex-col gap-5 px-4 pb-8 pt-28 sm:px-6 lg:px-12 xl:px-16">
          <div class="flex items-end gap-5">
            <img
              :if={@title && @title[:poster]}
              src={Roki.Images.local(@title.poster)}
              alt=""
              class="hidden h-44 w-auto shrink-0 rounded-xl shadow-2xl ring-1 ring-white/15 sm:block"
            />
            <div class="min-w-0 flex-1 space-y-3">
              <.link
                navigate={back_path(@type, @id)}
                class="inline-flex h-9 items-center gap-1.5 rounded-full border border-white/25 bg-black/30 px-3.5 text-sm font-medium backdrop-blur-md transition hover:border-white/60 hover:bg-black/45"
              >
                <.icon name="hero-arrow-left-micro" class="h-4 w-4" />
                {if @title, do: "Back to " <> @title.title, else: "Back"}
              </.link>
              <p class="text-xs font-semibold uppercase tracking-[0.25em] text-white/70">
                Choose a release
              </p>
              <h1 class="text-4xl font-bold leading-[1.04] tracking-tight drop-shadow-lg sm:text-5xl xl:text-6xl">
                {if @title, do: @title.title, else: "Sources"}
              </h1>
              <p class="text-lg text-white/75">
                <span :if={@title}>{[@title[:year]] |> Enum.filter(& &1) |> Enum.join(" · ")}</span>
                <span>{now_playing(@title || %{type: @type}, @season, @episode)}</span>
              </p>
            </div>
          </div>

          <div :if={(@next || @prev) && @external == nil} class="flex flex-wrap gap-2">
            <button
              :if={@prev}
              phx-click="previous"
              class="inline-flex h-10 items-center gap-1.5 rounded-full border border-white/25 bg-black/30 px-4 text-sm font-semibold backdrop-blur-md transition hover:border-white/60 hover:bg-black/45"
              title="The episode before"
            >
              <.icon name="hero-backward" class="h-4 w-4" />
              <span class="hidden sm:inline">Previous ·</span> {elem(@prev, 2)}
            </button>
            <button
              :if={@next}
              phx-click="next"
              class="inline-flex h-10 items-center gap-1.5 rounded-full border border-white/25 bg-black/30 px-4 text-sm font-semibold backdrop-blur-md transition hover:border-white/60 hover:bg-black/45"
              title="The next episode"
            >
              <span class="hidden sm:inline">Next ·</span> {elem(@next, 2)}
              <.icon name="hero-forward" class="h-4 w-4" />
            </button>
          </div>
        </div>
      </section>

      <div class="space-y-6 px-4 pb-12 pt-6 sm:px-6 lg:px-12 xl:px-16">
        <div :if={@uuid == nil and @source == :torrent} class="alert text-sm">
          <span>Log in, and connect your debrid account through laev, to watch here.</span>
          <a href="/phoenix_kit/users/log-in" class="btn btn-sm">Log in</a>
        </div>

        <p :if={@title_error} class="alert alert-error">
          Couldn't load this title just now. Try again in a minute.
        </p>

        <.source_bar
          :if={@uuid != nil}
          source={@source}
          avail={@avail}
          settings={@settings}
          cached_at={@cached_at}
          busy={@phase == :working}
          pengu={@pengu}
          nuvio={@nuvio}
        />
        <.cache_note
          :if={@cached_at != nil and @uuid == nil}
          at={@cached_at}
          busy={@phase == :working}
        />

        <.connect_sources
          :if={@uuid != nil and not @avail[@source]}
          avail={@avail}
          source={@source}
          settings={@settings}
          msg={@setup_msg}
          busy={@setup_busy}
        />

        <.progress_line
          :if={@source == :torrent and @phase in [:loading, :working] and @auto != :pending}
          probe={@probe}
          text={@status}
        />
        <.checks_list
          :if={@source == :torrent and @phase in [:loading, :working] and @auto != :pending}
          checks={@checks}
        />
        <p :if={@source == :torrent and @start_error} class="alert alert-warning text-sm">
          {@start_error}
        </p>
        <p :if={@source == :torrent and @phase == :failed} class="alert alert-warning text-sm">
          {@failed}
        </p>
        <.heavy_offer :if={
          @source == :torrent and @phase == :failed and @failed_reason == :no_light and
            @mode == :browser and
            @heavy_allowed?
        } />
        <p
          :if={
            @source == :torrent and @phase == :ready and @playable != [] and @external == nil and
              @auto != :pending
          }
          class="text-sm text-base-content/70"
        >
          Pick a release.
        </p>

        <.external_panel
          :if={@source == :torrent and @external}
          external={@external}
          platform={@platform}
          title={@title}
          season={@season}
          episode={@episode}
          next={@next}
          prev={@prev}
        />

        <.sources
          :if={@source == :torrent and @playable != []}
          playable={@playable}
          caps={@caps}
          rest={@rest}
          current={@current}
          mode={@mode}
          busy={@busy?}
          limit={limit(@mode, @uuid, @caps)}
        />

        <.pengu_sources
          :if={@source == :pengu and @avail.pengu}
          pengu={@pengu}
          auto={@auto}
          type={@type}
          id={@id}
          season={@season}
          episode={@episode}
        />

        <.nuvio_sources
          :if={@source == :nuvio and Map.get(@avail, :nuvio, false)}
          nuvio={@nuvio}
          auto={@auto}
          type={@type}
          id={@id}
          season={@season}
          episode={@episode}
          settings={@settings}
        />
      </div>

      <.auto_start
        :if={
          @source == :torrent and @linked? and @auto == :pending and
            @phase in [:loading, :working] and @external == nil
        }
        probe={@probe}
        checks={@checks}
        what={if @title, do: @title.title <> now_playing(@title, @season, @episode)}
      />

      <.starting :if={@starting} name={@starting.name} />
    </Layouts.app>
    """
  end

  # ── PenguPlay: a second search, on request ──────────────────────────

  attr :kind, :atom, required: true
  attr :label, :string, required: true
  attr :source, :atom, required: true
  attr :avail, :map, required: true
  attr :missing, :string, required: true
  attr :hint, :string, required: true

  # One side of the switch: a button when the account has it, else greyed and a link to Settings.
  defp source_choice(assigns) do
    ~H"""
    <button
      :if={@avail[@kind]}
      type="button"
      phx-click="source"
      phx-value-to={@kind}
      aria-pressed={@source == @kind}
      class={["btn btn-sm join-item", @source == @kind && "btn-primary"]}
    >
      {@label}
    </button>
    <.link
      :if={not @avail[@kind]}
      navigate={@missing}
      title={@hint}
      class="btn btn-sm join-item btn-ghost opacity-50 hover:opacity-80"
    >
      {@label}
    </.link>
    """
  end

  attr :avail, :map, required: true
  attr :source, :atom, required: true
  attr :settings, :string, required: true
  attr :msg, :any, default: nil
  attr :busy, :boolean, default: false

  # What to do when nothing is connected for the kind of source being looked at: where each one
  # comes from, and a field to paste it into. The page works as soon as one is saved.
  defp connect_sources(assigns) do
    ~H"""
    <section class="space-y-4 rounded-2xl border border-primary/30 bg-primary/5 p-5">
      <div class="space-y-1">
        <h2 class="text-xl font-semibold">Connect a source to start watching</h2>
        <p class="text-sm text-base-content/70">
          Roki plays from sources of your own, so nothing plays until one is connected. Pick
          whichever suits you — the original collection needs a debrid account, PenguPlay is
          free, and Nuvio runs providers you choose in Settings.
        </p>
      </div>

      <p :if={match?({:error, _}, @msg)} class="alert alert-warning text-sm">{elem(@msg, 1)}</p>

      <div class="grid gap-4 lg:grid-cols-2">
        <div class="space-y-3 rounded-xl border border-base-300 bg-base-100/70 p-4">
          <h3 class="font-semibold">
            PenguPlay <span class="badge badge-success badge-sm ml-1">free</span>
          </h3>
          <ol class="list-decimal space-y-1 pl-5 text-sm text-base-content/70">
            <li>
              Open
              <a href="https://pengu.uk" target="_blank" rel="noopener" class="link link-primary">pengu.uk</a>
              and sign in with Google — about ten seconds.
            </li>
            <li>
              Pick the providers you want, then copy the install link (it ends in <code>/manifest.json</code>).
            </li>
            <li>Paste it here.</li>
          </ol>
          <form phx-submit="setup_pengu" class="flex flex-wrap gap-2">
            <input
              type="text"
              name="pengu[url]"
              autocomplete="off"
              spellcheck="false"
              placeholder="https://pengu.uk/…/manifest.json"
              class="input input-bordered input-sm min-w-0 flex-1"
            />
            <button class="btn btn-sm btn-primary">Connect</button>
          </form>
        </div>

        <div class="space-y-3 rounded-xl border border-base-300 bg-base-100/70 p-4">
          <h3 class="font-semibold">
            Nuvio <span class="badge badge-ghost badge-sm ml-1">settings</span>
          </h3>
          <p class="text-sm text-base-content/70">
            Nuvio providers are discovered from the All-in-One-Nuvio manifest and run in an
            isolated Node process. Switch on the ones you want to use; nothing is on by default.
          </p>
          <a href={@settings <> "#nuvio"} class="btn btn-sm btn-primary">
            Choose Nuvio providers
          </a>
        </div>

        <div class="space-y-3 rounded-xl border border-base-300 bg-base-100/70 p-4">
          <h3 class="font-semibold">
            Real-Debrid or TorBox
            <span class="badge badge-ghost badge-sm ml-1">paid, for torrents</span>
          </h3>
          <ol class="list-decimal space-y-1 pl-5 text-sm text-base-content/70">
            <li>
              Sign up at
              <a
                href="https://real-debrid.com"
                target="_blank"
                rel="noopener"
                class="link link-primary"
              >real-debrid.com</a>
              or
              <a href="https://torbox.app" target="_blank" rel="noopener" class="link link-primary">torbox.app</a>
              (either one).
            </li>
            <li>
              Copy your key:
              <a
                href="https://real-debrid.com/apitoken"
                target="_blank"
                rel="noopener"
                class="link link-primary"
              >Real-Debrid API token</a>
              · <a
                href="https://torbox.app/settings"
                target="_blank"
                rel="noopener"
                class="link link-primary"
              >TorBox API key</a>.
            </li>
            <li>Paste it below. It is checked with the service before it is kept.</li>
          </ol>
          <form phx-submit="setup_debrid" class="space-y-2">
            <input
              type="password"
              name="debrid[RD_TOKEN]"
              autocomplete="off"
              spellcheck="false"
              placeholder="Real-Debrid API token"
              class="input input-bordered input-sm w-full font-mono"
            />
            <input
              type="password"
              name="debrid[TORBOX_API_KEY]"
              autocomplete="off"
              spellcheck="false"
              placeholder="TorBox API key"
              class="input input-bordered input-sm w-full font-mono"
            />
            <button class="btn btn-sm btn-primary" disabled={@busy}>
              <span :if={@busy} class="loading loading-spinner loading-xs"></span> Connect
            </button>
          </form>
        </div>
      </div>
    </section>
    """
  end

  attr :source, :atom, required: true
  attr :avail, :map, required: true
  attr :settings, :string, required: true
  attr :cached_at, :any, default: nil
  attr :busy, :boolean, default: false
  attr :pengu, :any, default: nil
  attr :nuvio, :any, default: nil

  # The row above the results: which kind of source is being looked at, and — beside it — how
  # fresh they are and the button that looks again.
  defp source_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-2xl border border-base-300/70 bg-base-100/60 px-4 py-3 text-sm text-base-content/70">
      <div class="join" role="group" aria-label="Where to look for sources">
        <.source_choice
          kind={:torrent}
          label="Torrents"
          source={@source}
          avail={@avail}
          missing={@settings <> "#debrid"}
          hint="Needs a Real-Debrid or TorBox account — add it in Settings"
        />
        <.source_choice
          kind={:pengu}
          label="PenguPlay"
          source={@source}
          avail={@avail}
          missing={@settings <> "#penguplay"}
          hint="Needs a PenguPlay link — add it in Settings"
        />
        <.source_choice
          kind={:nuvio}
          label="Nuvio"
          source={@source}
          avail={@avail}
          missing={@settings <> "#nuvio"}
          hint="Needs at least one Nuvio provider — choose them in Settings"
        />
      </div>

      <%= cond do %>
        <% @source == :torrent -> %>
          <span :if={@cached_at} class="badge badge-success badge-outline gap-1">⚡ cached sources</span>
          <span :if={@cached_at}>found {ago(@cached_at)}, nothing to check.</span>
          <button :if={@cached_at} phx-click="retry" class="btn btn-xs rounded-full" disabled={@busy}>
            Retry
          </button>
          <span :if={@cached_at} class="text-base-content/50">looks for new ones</span>
        <% @source == :pengu -> %>
          <span :if={match?({:ok, _, _}, @pengu)}>{elem(@pengu, 2)} streams found.</span>
          <button
            :if={@pengu != :loading and @pengu != nil}
            type="button"
            phx-click="pengu"
            class="btn btn-xs rounded-full"
          >
            Search again
          </button>
        <% @source == :nuvio -> %>
          <span :if={match?({:ok, _}, @nuvio)}>
            {Roki.Nuvio.count(elem(@nuvio, 1))} streams from {length(elem(@nuvio, 1))} providers.
          </span>
          <button
            :if={@nuvio != :loading and @nuvio != nil}
            type="button"
            phx-click="nuvio"
            class="btn btn-xs rounded-full"
          >
            Search again
          </button>
          <span class="text-base-content/50">
            <a href={@settings <> "#nuvio"} class="link">Choose providers</a>
          </span>
        <% true -> %>
      <% end %>
    </div>
    """
  end

  attr :pengu, :any, required: true
  attr :auto, :atom, default: :off
  attr :type, :string, required: true
  attr :id, :integer, required: true
  attr :season, :integer, default: nil
  attr :episode, :integer, default: nil

  defp pengu_sources(assigns) do
    ~H"""
    <section class="space-y-3">
      <div
        :if={@pengu in [nil, :loading]}
        class="flex items-center gap-3 rounded-2xl border border-base-300/70 bg-base-100/60 p-4 text-sm"
      >
        <span class="loading loading-spinner loading-sm"></span>
        {if @auto == :pending,
          do: "Finding the best source…",
          else: "Asking the PenguPlay providers… this can take up to a minute."}
      </div>
      <p :if={match?({:error, _}, @pengu)} class="alert alert-warning text-sm">{elem(@pengu, 1)}</p>
      <p :if={match?({:ok, [], _}, @pengu)} class="text-sm text-base-content/60">
        PenguPlay found nothing for this.
      </p>
      <p :if={match?({:ok, [_ | _], _}, @pengu)} class="text-sm text-base-content/70">
        Pick a stream.
      </p>
      <div :if={match?({:ok, [_ | _], _}, @pengu)} class="space-y-5">
        <div :for={{provider, streams} <- elem(@pengu, 1)} class="space-y-2">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            {provider}
          </h3>
          <ul class="space-y-2">
            <li :for={s <- streams}>
              <.link
                navigate={pengu_watch(@type, @id, @season, @episode, s.id)}
                class="group flex w-full items-center gap-4 rounded-2xl border border-base-300 bg-base-100/70 p-4 text-left transition hover:border-primary/60 hover:bg-base-100"
              >
                <div class="min-w-0 flex-1 space-y-1.5">
                  <div class="truncate text-sm font-medium" title={s.label}>
                    {if s.name != "", do: s.name, else: s.label}
                  </div>
                  <div class="flex flex-wrap items-center gap-1.5 text-xs">
                    <span :if={s.quality != ""} class="badge badge-sm badge-primary">{s.quality}</span>
                    <span :if={s.size != ""} class="badge badge-sm badge-ghost">{s.size}</span>
                    <span class="badge badge-sm badge-ghost">{provider}</span>
                    <span :if={s.language != ""} class="text-base-content/60">🔊 {s.language}</span>
                    <span :if={s.subtitles != []} class="text-base-content/60">💬 {length(s.subtitles)}</span>
                  </div>
                </div>
                <span class="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary transition group-hover:bg-primary group-hover:text-primary-content">
                  <.icon name="hero-play-solid" class="h-5 w-5" />
                </span>
              </.link>
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  attr :nuvio, :any, required: true
  attr :auto, :atom, default: :off
  attr :type, :string, required: true
  attr :id, :integer, required: true
  attr :season, :integer, default: nil
  attr :episode, :integer, default: nil
  attr :settings, :string, required: true

  defp nuvio_sources(assigns) do
    ~H"""
    <section class="space-y-4">
      <div
        :if={@nuvio in [nil, :loading]}
        class="flex items-center gap-3 rounded-2xl border border-base-300/70 bg-base-100/60 p-4 text-sm"
      >
        <span class="loading loading-spinner loading-sm"></span>
        {if @auto == :pending,
          do: "Finding a Nuvio stream…",
          else: "Asking the selected Nuvio providers, each in its own sandbox…"}
      </div>
      <p :if={match?({:error, _}, @nuvio)} class="alert alert-warning text-sm">{elem(@nuvio, 1)}</p>

      <%= if match?({:ok, _}, @nuvio) do %>
        <p :if={Roki.Nuvio.count(elem(@nuvio, 1)) == 0} class="text-sm text-base-content/60">
          No Nuvio provider returned a playable stream. The providers and their errors are listed
          below; a provider whose site is down does not stop the others.
        </p>
        <div :for={result <- elem(@nuvio, 1)} class="space-y-2">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              {result.provider.name}
            </h3>
            <span class={[
              "badge badge-sm",
              result.status == :ok && "badge-success",
              result.status in [:empty, :timeout, :error] && "badge-warning",
              result.status == :blocked && "badge-error"
            ]}>
              {Roki.Nuvio.status_text(result)}
            </span>
            <span :if={result.provider.verification == :obfuscated} class="badge badge-ghost badge-sm">
              sandboxed · obfuscated
            </span>
            <span :if={result.error} class="text-xs text-base-content/50">{result.error}</span>
          </div>
          <ul :if={result.streams != []} class="space-y-2">
            <li :for={s <- result.streams}>
              <.link
                navigate={nuvio_watch(@type, @id, @season, @episode, s.provider_id, s.id)}
                class="group flex w-full items-center gap-4 rounded-2xl border border-base-300 bg-base-100/70 p-4 text-left transition hover:border-primary/60 hover:bg-base-100"
              >
                <div class="min-w-0 flex-1 space-y-1.5">
                  <div class="truncate text-sm font-medium" title={s.label}>
                    {if s.name != "", do: s.name, else: s.label}
                  </div>
                  <div class="flex flex-wrap items-center gap-1.5 text-xs">
                    <span :if={s.quality != ""} class="badge badge-sm badge-primary">{s.quality}</span>
                    <span :if={s.size != ""} class="badge badge-sm badge-ghost">{s.size}</span>
                    <span class="badge badge-sm badge-ghost">{result.provider.name}</span>
                    <span :if={s.language != ""} class="text-base-content/60">🔊 {s.language}</span>
                    <span :if={s.subtitles != []} class="text-base-content/60">💬 {length(s.subtitles)}</span>
                  </div>
                </div>
                <span class="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary transition group-hover:bg-primary group-hover:text-primary-content">
                  <.icon name="hero-play-solid" class="h-5 w-5" />
                </span>
              </.link>
            </li>
          </ul>
        </div>
      <% end %>
    </section>
    """
  end

  defp nuvio_watch(%{type: type, id: id, season: s, episode: e}, provider_id, sid),
    do: nuvio_watch(type, id, s, e, provider_id, sid)

  defp nuvio_watch("movie", id, _s, _e, provider_id, sid),
    do: ~p"/watch/movie/#{id}?#{[nv: "#{provider_id}:#{sid}"]}"

  defp nuvio_watch("tv", id, s, e, provider_id, sid),
    do: ~p"/watch/tv/#{id}/#{s}/#{e}?#{[nv: "#{provider_id}:#{sid}"]}"

  defp pengu_watch(%{type: type, id: id, season: s, episode: e}, sid),
    do: pengu_watch(type, id, s, e, sid)

  defp pengu_watch("movie", id, _s, _e, sid), do: ~p"/watch/movie/#{id}?#{[pg: sid]}"
  defp pengu_watch("tv", id, s, e, sid), do: ~p"/watch/tv/#{id}/#{s}/#{e}?#{[pg: sid]}"

  defp back_path("movie", id), do: ~p"/title/movie/#{id}"
  defp back_path("tv", id), do: ~p"/title/tv/#{id}/episodes"
end
