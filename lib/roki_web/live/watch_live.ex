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
  require Logger

  import RokiWeb.StudyComponents
  import RokiWeb.WatchComponents, only: [now_playing: 3, checks_list: 1, heavy_offer: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Watch
  alias Roki.Watch.{Resolver, SourceCache}

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    type = if params["season"], do: "tv", else: "movie"

    with {n, ""} <- Integer.parse(id),
         {season, episode} <- parse_episode(params),
         scope = socket.assigns[:phoenix_kit_current_scope],
         uuid = if(scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)) do
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
          # `?pg=` plays a PenguPlay stream (from the sources page's PenguPlay search) instead of
          # a debrid release: no laev account needed, the video is read from its host directly.
          pengu: if(uuid && is_binary(params["pg"]), do: String.slice(params["pg"], 0, 32)),
          # `?auto=1` with it: Play picked the stream, so a stream that fails is followed by the next best.
          pengu_auto: params["auto"] == "1",
          pengu_tried: [],
          torrent_forced: params["src"] == "torrent" or params["study"] == "1",
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
          failed_reason: nil,
          skip: [],
          heavy_ok: false,
          fallback?: false,
          decode_prompt: nil,
          heavy_allowed?: uuid != nil and Roki.Keys.heavy?(uuid),
          caps: caps_param(socket),
          episodes: nil,
          up_next: nil,
          up_prev: nil
        )

      {:ok,
       if(connected?(socket) and (socket.assigns.linked? or socket.assigns.pengu),
         do: load(socket),
         else: socket
       )}
    else
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

    heavy_ok = socket.assigns.heavy_ok
    caps = socket.assigns.caps
    # Releases that did not work for this episode are left out, a chosen one included.
    skip = socket.assigns.skip
    hash = if hash in skip, do: nil, else: hash

    parent = self()

    socket
    |> assign(
      token: token,
      failed: nil,
      failed_reason: nil,
      player: nil,
      checks: [],
      decode_prompt: nil
    )
    |> start_async(
      :resolve,
      Roki.Study.wrap(fn ->
        with {:ok, res} <-
               Resolver.run(
                 parent,
                 token,
                 uuid,
                 title,
                 season,
                 episode,
                 false,
                 :browser,
                 true,
                 heavy_ok,
                 caps
               ),
             res = without(parent, token, uuid, heavy_ok, caps, res, skip),
             {res, pair} <-
               locate(
                 parent,
                 token,
                 uuid,
                 {heavy_ok, caps},
                 res,
                 hash || prefer,
                 if(hash, do: 3, else: 1)
               ),
             pair = if(hash, do: pair, else: within_cap(res, pair)),
             {:ok, pair} <- choose(res, pair, caps),
             :ok <-
               announce(
                 parent,
                 token,
                 if(Watch.local_player?(uuid, caps),
                   do: "Opening the video…",
                   else: "Getting the video ready…"
                 )
               ),
             {:ok, pair, player} <-
               start_or_next(parent, token, uuid, caps, res, pair, hash == nil, skip, 4) do
          {:ok, token, res, pair, player}
        else
          {:error, ^token, reason} -> {:error, token, reason}
          {:error, reason} -> {:error, token, reason}
        end
      end)
    )
  end

  # The stream named in the address, among what PenguPlay found for this title (kept ten minutes,
  # so a click from the sources page is no second search).
  defp play_pengu(socket) do
    %{title: title, season: season, episode: episode, pengu: id} = socket.assigns

    %{uuid: uuid, linked?: linked?} = socket.assigns

    start_async(socket, :pengu, fn ->
      with {:ok, streams} <- Roki.Pengu.streams(uuid, title.imdb_id, season, episode) do
        case Roki.Pengu.find(streams, id) do
          nil ->
            {:error, :gone}

          stream ->
            # History and the place to resume from live in the laev account, so they need one.
            if linked? do
              ctx = Watch.ctx(uuid, title, season, episode)
              {:ok, stream, ctx, Watch.pengu_start(uuid, ctx)}
            else
              {:ok, stream, nil, 0}
            end
        end
      end
    end)
  end

  # After a stream Play picked failed: the next best from the same search (kept ten minutes), up to
  # four in a row. A stream chosen by hand is not replaced behind the viewer's back.
  defp next_pengu(%{pengu_auto: true, title: %{imdb_id: imdb}} = a, tried) when length(tried) < 4 do
    with {:ok, streams} <- Roki.Pengu.streams(a.uuid, imdb, a.season, a.episode),
         do: Roki.Pengu.best(streams, a.caps, tried)
  end

  defp next_pengu(_assigns, _tried), do: nil

  # Play on an account that looks at PenguPlay first, arriving here with nothing chosen.
  defp pengu_default?(%{hash: nil, torrent_forced: false, uuid: uuid}) when is_binary(uuid) do
    avail = Roki.Sources.available(uuid)
    avail.pengu and Roki.Sources.current(uuid, avail) == :pengu
  end

  defp pengu_default?(_), do: false

  # Another episode of the title playing: from PenguPlay, back through the sources page asking for
  # its best stream (the next episode is another search); from a release, straight to that release.
  defp episode_path(%{assigns: %{pengu: pg, id: id}}, s, e, _query) when is_binary(pg),
    do: ~p"/sources/tv/#{id}/#{s}/#{e}?#{[src: "pengu", auto: 1]}"

  defp episode_path(%{assigns: %{id: id}} = socket, s, e, query),
    do: ~p"/watch/tv/#{id}/#{s}/#{e}?#{query ++ study_q(socket)}"

  defp current_path(%{type: "movie", id: id}), do: ~p"/watch/movie/#{id}"
  defp current_path(%{type: "tv", id: id, season: s, episode: e}), do: ~p"/watch/tv/#{id}/#{s}/#{e}"

  defp pengu_failure(:gone),
    do: "That PenguPlay source is no longer listed. Go back and search again."

  defp pengu_failure(reason), do: Roki.Pengu.message(reason)

  # What did not work before is left out; when that is all that was checked, look at more.
  defp without(_parent, _token, _uuid, _heavy_ok, _caps, res, []), do: res

  defp without(parent, token, uuid, heavy_ok, caps, res, skip) do
    keep = Enum.reject(res.playable, fn {source, _} -> source.hash in skip end)
    res = %{res | playable: keep}

    if keep == [] and res.rest != [] do
      hours = SourceCache.hours(Roki.Laev.web_settings(uuid))

      {:ok, _token, all, rest} =
        Resolver.more(
          parent,
          token,
          uuid,
          res.ctx,
          res.rest,
          [],
          res.key,
          hours,
          Resolver.light?(:browser, uuid, heavy_ok),
          caps
        )

      without(parent, token, uuid, heavy_ok, caps, %{res | playable: all, rest: rest}, skip)
    else
      res
    end
  end

  # Start the release; when it will not (its host is silent, it needs more than this account may
  # use) and the choice was ours rather than the user's, go on with the next best instead of
  # stopping. The ones that failed are told to the page so a retry leaves them out.
  @unskippable [:busy, :over_limit, :no_provider]
  defp start_or_next(parent, token, uuid, caps, res, {source, _} = pair, auto?, tried, left) do
    case start(uuid, res.ctx, pair, caps) do
      {:ok, player} ->
        {:ok, pair, player}

      {:error, reason} ->
        tried = [source.hash | tried]
        send(parent, {:tried, token, tried})
        # A release that would not start is not kept as the one to go straight to.
        if res.key and skippable?(reason), do: SourceCache.mark_bad(uuid, res.key, source.hash)
        next = if auto? and left > 0 and skippable?(reason), do: next_pair(res, tried, caps)

        if next do
          announce(parent, token, "That release didn't work — trying another…")
          start_or_next(parent, token, uuid, caps, res, next, auto?, tried, left - 1)
        else
          {:error, reason}
        end
    end
  end

  defp skippable?(reason) when reason in @unskippable, do: false
  defp skippable?({:busy, _}), do: false
  defp skippable?({:expired, _}), do: false
  defp skippable?(_), do: true

  defp next_pair(res, tried, caps) do
    left = Enum.reject(res.playable, fn {source, _} -> source.hash in tried end)

    case Enum.filter(left, fn {source, _} ->
           Laev.Sources.resolution_at_most?(source.resolution, res.cap)
         end) do
      [] -> nil
      within -> pick(%{res | playable: within}, caps)
    end
  end

  # A shared address names a release. It may not be among the first ones checked, so look further
  # (a few pages) before settling for the best.
  defp locate(_parent, _token, _uuid, _how, res, nil, _pages), do: {res, nil}

  defp locate(parent, token, uuid, {heavy_ok, caps} = how, res, hash, pages) do
    case Resolver.find(res.playable, hash) do
      nil when pages > 0 and res.rest != [] ->
        hours = SourceCache.hours(Roki.Laev.web_settings(uuid))

        {:ok, _token, all, rest} =
          Resolver.more(
            parent,
            token,
            uuid,
            res.ctx,
            res.rest,
            res.playable,
            res.key,
            hours,
            Resolver.light?(:browser, uuid, heavy_ok),
            caps
          )

        locate(parent, token, uuid, how, %{res | playable: all, rest: rest}, hash, pages - 1)

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

  defp choose(res, nil, caps) do
    case pick(res, caps) do
      nil -> {:error, :none_playable}
      pair -> {:ok, pair}
    end
  end

  defp choose(_res, pair, _caps), do: {:ok, pair}

  defp pick(res, caps) do
    case Resolver.pick(res.playable, res.cap, res.good, :browser, caps) do
      {:play, pair} -> pair
      _ -> List.first(res.playable)
    end
  end

  # The languages offered as OpenSubtitles choices: theirs first, then the usual few.
  # Study mode's subtitles: the language being studied is the main track, the translation (the
  # account's language unless another was chosen) shows under it. Nil outside study mode.
  defp study_subtitles(uuid, %{} = study) do
    learn = Watch.short_code(study["subs"])
    tr = Watch.short_code(Roki.Study.translate(uuid, study))
    %{learn: learn, translate: if(tr in ["", learn], do: "", else: tr)}
  end

  defp study_subtitles(_uuid, _study), do: nil

  defp os_langs(prefer),
    do:
      Enum.uniq(
        Enum.reject([prefer, "en", "fr", "ja", "es", "de", "pt", "it", "ru"], &(&1 in [nil, ""]))
      )

  defp start(uuid, ctx, {source, stream}, caps), do: Watch.start(uuid, ctx, source, stream, caps)

  # What this browser said it decodes itself, sent with the connection (see app.js).
  defp caps_param(socket) do
    params = if connected?(socket), do: get_connect_params(socket) || %{}, else: %{}
    Roki.Direct.caps(params["caps"])
  end

  @impl true
  def handle_async(:title, {:ok, {:ok, title}}, socket) do
    %{uuid: uuid, season: season, episode: episode} = socket.assigns
    title = Map.put(title, :tag, Watch.episode_tag(uuid, title, season, episode))
    socket = assign(socket, title: title, page_title: title.title)

    socket =
      if socket.assigns.type == "tv",
        do: load_episodes(socket),
        else: socket

    cond do
      socket.assigns.pengu -> {:noreply, play_pengu(socket)}
      pengu_default?(socket.assigns) -> {:noreply, push_navigate(socket, to: sources_path(socket.assigns, "pengu") <> "?auto=1", replace: true)}
      true -> {:noreply, resolve(socket)}
    end
  end

  def handle_async(:title, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :title_error, reason || true)}

  def handle_async(:title, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :title_error, reason)}

  def handle_async(:pengu, {:ok, {:ok, stream, ctx, from}}, socket) do
    local? = stream.kind == :file and socket.assigns.caps[:local] == true

    # A playlist is read from PenguPlay directly (it allows cross-origin reads, and so do its
    # segments); a file's link redirects to a host that often does not, so its bytes come by way of
    # the relay, which follows the redirect here.
    url = if stream.kind == :hls, do: stream.url, else: RokiWeb.Relay.url_for(stream.url)

    data = %{
      url: url,
      hls: stream.kind == :hls,
      hlsjs: stream.kind == :hls,
      local: local?,
      audio_lang: nil,
      filesize: nil,
      resume: from,
      start: 0,
      tracks: [],
      prefer: nil,
      key: Watch.pengu_play_id(stream.id),
      media: "pengu:#{socket.assigns.id}",
      os: nil,
      os_langs: [],
      study: nil,
      # A stream that has not started by then is counted as failed (and the next one tried).
      startup: 25_000
    }

    socket = socket |> assign(player: data, ctx: ctx) |> with_neighbours()

    # The subtitles the stream came with, then — for a linked account — its own language from
    # OpenSubtitles, as for any release.
    play_id = Watch.pengu_play_id(stream.id)
    subs = stream.subtitles

    {:noreply,
     start_async(socket, :pengu_subs, fn -> {play_id, Watch.pengu_tracks(play_id, subs)} end)}
  end

  def handle_async(:pengu_subs, {:ok, {play_id, tracks}}, %{assigns: %{player: %{} = player}} = socket)
      when is_binary(play_id) do
    %{uuid: uuid, ctx: ctx, token: token} = socket.assigns
    player = %{player | tracks: Enum.uniq_by(player.tracks ++ tracks, & &1.url)}
    socket = assign(socket, :player, player)

    langs = if ctx, do: Watch.external_langs(uuid, ctx, player.tracks), else: []

    socket =
      for lang <- langs, reduce: socket do
        acc ->
          start_async(
            acc,
            {:ext_subs, lang},
            Roki.Study.wrap(fn -> {token, external(uuid, ctx, play_id, lang, "PenguPlay")} end)
          )
      end

    {:noreply, socket}
  end

  def handle_async(:pengu_subs, _other, socket), do: {:noreply, socket}

  def handle_async(:pengu, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, failed: pengu_failure(reason), failed_reason: :pengu)}

  def handle_async(:pengu, {:exit, _}, socket),
    do: {:noreply, assign(socket, failed: pengu_failure(:timeout), failed_reason: :pengu)}

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
      local: player[:local] == true,
      audio_lang: player[:audio_lang],
      filesize: player[:filesize],
      resume: player.resume_at,
      start: player[:start] || 0,
      tracks: player.subtitles ++ saved,
      prefer: prefer,
      key: play_id,
      media: "#{res.ctx.type}:#{res.ctx.tmdb_id}",
      os: Watch.os_state(uuid),
      os_langs: os_langs(prefer),
      study: study_subtitles(uuid, socket.assigns.study)
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
      for lang <-
            Watch.external_langs(
              uuid,
              res.ctx,
              player.subtitles ++ saved,
              List.wrap(data.study && data.study.translate)
            ),
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
      do: {:noreply, assign(socket, failed: Resolver.failure(reason), failed_reason: reason)}

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

  # The same release again from further back (see "seek_back"): the player gets the new
  # stream's address and start, keeps its menus. The release's own subtitles are the new
  # part's files; fetched ones are the whole film's and stay.
  def handle_async(
        :restart,
        {:ok, {token, {:ok, p}}},
        %{assigns: %{token: token, player: %{} = player}} = socket
      ) do
    kept = Enum.reject(player.tracks, &String.starts_with?(&1.url, "/stream/#{p.remux_id}/sub"))

    data = %{
      player
      | url: p.url,
        resume: p.resume_at,
        start: p[:start] || 0,
        tracks: p.subtitles ++ kept
    }

    {:noreply, assign(socket, :player, data)}
  end

  def handle_async(:restart, _other, socket), do: {:noreply, socket}

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
  # This browser is not asked for HEVC/AV1/VP9 as they are again (it remembers).
  defp no_direct(socket) do
    socket
    |> assign(
      caps: Map.merge(socket.assigns.caps, %{hevc: false, av1: false, vp9: false, uhd: false}),
      fallback?: true
    )
    |> push_event("roki:nodirect", %{})
  end

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

  # The player reports the playhead every few seconds, and how much of the film it has really
  # played since it last said so — the page counts that itself, so a report that never arrives
  # costs nothing (see `measure()` in study/sidebar.js).
  @impl true
  def handle_event("progress", %{"position" => position, "duration" => duration} = params, socket) do
    %{uuid: uuid, ctx: ctx} = socket.assigns

    if uuid && ctx && is_number(position) do
      case Watch.record_progress(uuid, ctx, position, duration || 0, params["paused"] == true,
             watched: params["watched"]
           ) do
        {:finished, true} -> {:noreply, assign(socket, :up_next, next_episode(socket.assigns))}
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # A seek to before where the conversion begins (one begun at the saved position has nothing
  # before it): the same release again from there, as a conversion of its own.
  def handle_event(
        "seek_back",
        %{"position" => position},
        %{assigns: %{current: {source, stream}, ctx: %{} = ctx, uuid: uuid}} = socket
      )
      when is_number(position) and is_binary(uuid) do
    %{caps: caps, token: token} = socket.assigns

    {:noreply,
     start_async(
       socket,
       :restart,
       Roki.Study.wrap(fn ->
         {token, Watch.restart(uuid, ctx, source, stream, caps, trunc(position))}
       end)
     )}
  end

  def handle_event("seek_back", _params, socket), do: {:noreply, socket}

  # The page could not show the video it was given (no picture, or the media engine refused it).
  # Nothing is converted or replaced behind the viewer's back: they are asked. The two answers —
  # convert this release for the browser (the server re-encodes it to H.264, minutes of work), or
  # look for another file the browser plays as it is — are `convert_it` and `find_other`.
  # A PenguPlay stream the browser could not play: nothing to convert or replace here, so say so.
  def handle_event("player_failed", params, %{assigns: %{pengu: id, player: %{}}} = socket)
      when is_binary(id) do
    Logger.warning("pengu stream #{id} failed for #{socket.assigns.id}: #{inspect(params["why"])}")
    tried = [id | socket.assigns.pengu_tried]

    case next_pengu(socket.assigns, tried) do
      %{id: next} ->
        {:noreply,
         socket
         |> assign(pengu: next, pengu_tried: tried, player: nil)
         |> push_patch(to: "#{current_path(socket.assigns)}?#{URI.encode_query(pg: next, auto: 1)}", replace: true)
         |> play_pengu()}

      nil ->
        {:noreply,
         assign(socket,
           player: nil,
           failed:
             "That stream would not play in this browser (#{String.slice(to_string(params["why"]), 0, 120)}). Try another PenguPlay source.",
           failed_reason: :pengu
         )}
    end
  end

  def handle_event(
        "player_failed",
        %{"local" => true} = params,
        %{assigns: %{player: %{local: true}, current: {source, _}}} = socket
      ) do
    Logger.warning(
      "local player failed for #{socket.assigns.id} (#{inspect(source.name)}): #{inspect(params["why"])} — the server takes over"
    )

    {:noreply,
     socket
     |> assign(
       caps: Map.put(socket.assigns.caps, :local, false),
       status: "This device could not play it as it is — the server is preparing it…"
     )
     |> resolve()}
  end

  def handle_event(
        "player_failed",
        params,
        %{assigns: %{player: %{}, current: {source, _}}} = socket
      ) do
    caps = socket.assigns.caps

    Logger.warning(
      "player failed for #{socket.assigns.id} (#{inspect(source.name)}): #{inspect(params["why"])} #{inspect(params["ua"])}"
    )

    if not socket.assigns.fallback? and not Roki.Direct.wanted?(source, %{}) and
         Enum.any?([:hevc, :av1, :vp9], &(caps[&1] == true)) do
      {:noreply,
       assign(socket,
         player: nil,
         decode_prompt: %{
           name: source.name,
           hash: source.hash,
           can_convert?: socket.assigns.heavy_allowed?
         }
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("player_failed", _params, socket), do: {:noreply, socket}

  # "Convert it": the same release, re-encoded here to something every browser plays.
  def handle_event(
        "convert_it",
        _params,
        %{assigns: %{decode_prompt: %{can_convert?: true}}} = socket
      ) do
    {:noreply,
     socket
     |> no_direct()
     |> assign(
       heavy_ok: true,
       status: "Converting it so this browser can play it — this takes a few minutes…"
     )
     |> resolve()}
  end

  # "Find another file": this release is set aside and a different one is looked for — one this
  # browser plays as it is, in the audio and subtitles asked for.
  def handle_event("find_other", _params, %{assigns: %{decode_prompt: %{hash: hash}}} = socket) do
    {:noreply,
     socket
     |> no_direct()
     |> assign(
       hash: nil,
       skip: Enum.uniq([hash | socket.assigns.skip]),
       status: "Looking for a file this browser can play…"
     )
     |> resolve()}
  end

  def handle_event(event, _params, socket) when event in ["convert_it", "find_other"],
    do: {:noreply, socket}

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

  # A pick from the player's episode menu: an episode of this season, or of another.
  def handle_event(
        "goto",
        %{"episode" => n} = params,
        %{assigns: %{type: "tv", season: s}} = socket
      )
      when is_integer(n) do
    s = if is_integer(params["season"]) and params["season"] >= 0, do: params["season"], else: s

    query =
      case socket.assigns.current do
        {source, _} -> [prefer: source.hash]
        _ -> []
      end

    {:noreply,
     push_navigate(socket,
       to: episode_path(socket, s, n, query),
       replace: true
     )}
  end

  # Another season picked in the episode menu: its episodes, for the menu to list.
  def handle_event(
        "season_episodes",
        %{"season" => s},
        %{assigns: %{type: "tv", id: id, uuid: uuid}} = socket
      )
      when is_integer(s) and s >= 0 do
    episodes =
      case Watch.episodes(id, s, uuid) do
        {:ok, eps} ->
          for e <- eps,
              do: %{
                n: e.number,
                name: e.name,
                ok: e.aired?,
                now: s == socket.assigns.season and e.number == socket.assigns.episode
              }

        _ ->
          []
      end

    {:reply, %{season: s, episodes: episodes}, socket}
  end

  def handle_event("season_episodes", _params, socket), do: {:reply, %{episodes: []}, socket}

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

  def handle_event("next", _params, %{assigns: %{up_next: {s, e}}} = socket) do
    query =
      case socket.assigns.current do
        {source, _} -> [prefer: source.hash]
        _ -> []
      end

    {:noreply,
     push_navigate(socket,
       to: episode_path(socket, s, e, query),
       replace: true
     )}
  end

  def handle_event("next", _params, socket), do: {:noreply, socket}

  def handle_event("previous", _params, %{assigns: %{up_prev: {s, e, _tag}}} = socket) do
    query =
      case socket.assigns.current do
        {source, _} -> [prefer: source.hash]
        _ -> []
      end

    {:noreply,
     push_navigate(socket,
       to: episode_path(socket, s, e, query),
       replace: true
     )}
  end

  def handle_event("previous", _params, socket), do: {:noreply, socket}

  # A heavy-allowed account says yes to re-encoded releases for this search only.
  def handle_event("search_heavy", _params, %{assigns: %{uuid: uuid}} = socket) do
    if Roki.Keys.heavy?(uuid),
      do: {:noreply, socket |> assign(heavy_ok: true) |> resolve()},
      else: {:noreply, socket}
  end

  # Look again leaving out the releases that did not work.
  def handle_event("try_another", _params, %{assigns: %{skip: [_ | _]}} = socket),
    do: {:noreply, resolve(socket)}

  def handle_event("try_another", _params, socket), do: {:noreply, socket}

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
         to: episode_path(socket, season, episode, query)
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

  def handle_info({:tried, token, hashes}, %{assigns: %{token: token}} = socket),
    do: {:noreply, update(socket, :skip, &Enum.uniq(&1 ++ hashes))}

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

  # Where "back" goes: the title (a series' episode list), not the list of releases.
  defp back_path(%{type: "movie", id: id}), do: ~p"/title/movie/#{id}"
  defp back_path(%{type: "tv", id: id}), do: ~p"/title/tv/#{id}/episodes"

  # The sources page, opened on the kind of source that is playing — so "Change source" lists the
  # PenguPlay streams after a PenguPlay one, and the releases after a release.
  defp sources_path(%{pengu: id} = a) when is_binary(id), do: sources_path(a, "pengu")
  defp sources_path(a), do: sources_path(a, "torrent")

  defp sources_path(a, src), do: sources_base(a) <> if(Roki.Pengu.configured?(a[:uuid]), do: "?src=#{src}", else: "")

  defp sources_base(%{type: "movie", id: id}), do: ~p"/sources/movie/#{id}"

  defp sources_base(%{type: "tv", id: id, season: s, episode: e}),
    do: ~p"/sources/tv/#{id}/#{s}/#{e}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/watch"
    >
      <div class="space-y-4">
        <div class="flex flex-wrap items-center gap-3">
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-4 text-sm text-base-content/60">
              <.link navigate={back_path(assigns)} class="hover:text-primary">
                ← {if @title, do: @title.title, else: "Back"}
              </.link>
              <.link navigate={sources_path(assigns)} class="hover:text-primary">Sources</.link>
            </div>
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
        <div :if={@uuid != nil and not @linked? and @pengu == nil} class="alert text-sm">
          <span>Nothing is connected to play this yet — PenguPlay (free) or a Real-Debrid / TorBox account.</span>
          <.link navigate={sources_path(assigns)} class="btn btn-sm">Connect a source</.link>
        </div>

        <p :if={@title_error} class="alert alert-error">
          Couldn't load this title just now. Try again in a minute.
        </p>

        <div
          :if={@decode_prompt}
          class="space-y-3 rounded-box border border-warning/40 bg-warning/10 p-5"
          role="alert"
        >
          <p class="font-semibold">This browser can't show this video as it is.</p>
          <p class="text-sm text-base-content/70">
            {@decode_prompt.name} is encoded in a way this browser can't decode. You choose what happens
            next — nothing is converted unless you say so.
          </p>
          <div class="flex flex-wrap gap-2">
            <button
              :if={@decode_prompt.can_convert?}
              type="button"
              phx-click="convert_it"
              class="btn btn-primary"
            >
              Convert it for this browser
              <span class="text-xs font-normal opacity-80">(takes a few minutes)</span>
            </button>
            <button type="button" phx-click="find_other" class="btn">
              Look for a different file
            </button>
          </div>
          <p :if={!@decode_prompt.can_convert?} class="text-xs text-base-content/60">
            Converting is not turned on for this account, so a different file is the way on. It will
            still be in the audio and subtitles you asked for.
          </p>
          <p class="text-xs text-base-content/60">
            Either way this browser will stop being sent videos like this one as they are.
          </p>
        </div>

        <div :if={@failed} class="space-y-3">
          <p class="alert alert-warning text-sm">{@failed}</p>
          <.heavy_offer :if={@failed_reason == :no_light and @heavy_allowed?} />
          <div class="flex flex-wrap gap-2">
            <button
              :if={@skip != [] and @failed_reason != :no_light}
              type="button"
              phx-click="try_another"
              class="btn btn-primary"
            >
              Try another source
            </button>
            <.link navigate={sources_path(assigns)} class="btn">Choose another source</.link>
          </div>
        </div>

        <div
          :if={
            (@linked? or @pengu != nil) and @player == nil and @failed == nil and @title_error == nil and
              @decode_prompt == nil
          }
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
      seasons={if @title, do: @title.seasons, else: []}
      season={@season}
      label={if @title, do: @title.title <> now_playing(@title, @season, @episode)}
      home={if @title, do: back_path(assigns), else: ~p"/home"}
      sources={sources_path(assigns)}
    />
    <style :if={@player}>
      html, body { overflow: hidden; height: 100%; overscroll-behavior: none; }
    </style>
    """
  end
end
