defmodule RokiWeb.TitleLive do
  @moduledoc """
  `/title/:type/:id` — a film or a show, and everything about it: the poster, what TMDB says,
  what you have done with it (saved, on hold, watched, rated) and Play.

  Play does not play here. A film's Play opens its sources (`SourcesLive`), a series' Play opens
  the page of its episodes (`/title/tv/:id/episodes`, the `:episodes` action of this same module),
  and an episode's Play opens that episode's sources. From the sources, choosing a release opens
  the player page (`WatchLive`) or, on an external player, the app.
  """
  use RokiWeb, :live_view
  use PhoenixKitComments.Embed

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Watch
  alias RokiWeb.ScoreColor
  alias Roki.Watch.SourceCache

  # ── mount & params ─────────────────────────────────────────────────

  @impl true
  def mount(%{"type" => type, "id" => id}, _session, socket) do
    case {type in ~w(movie tv), Integer.parse(id)} do
      {true, {n, ""}} -> {:ok, init(socket, type, n)}
      _ -> {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  def mount(%{"id" => id}, _session, socket) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, init(socket, "tv", n)}
      _ -> {:ok, push_navigate(socket, to: ~p"/")}
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
        cached: MapSet.new(),
        lib: %{saved?: false, held?: false, watched?: false, all_watched?: false},
        lib_busy: false,
        solo?: false,
        link_state: :none,
        trailer: nil,
        credits: Roki.Credits.empty(),
        rating: %{state: :loading, value: nil, provider: :tmdb},
        rate_mal: nil,
        rating_error: nil,
        reviews: nil,
        similar: [],
        similar_seen: MapSet.new(),
        study: nil,
        study_eps: nil,
        page_title: "Watch",
        title: nil,
        title_error: nil,
        resume: nil,
        resume_secs: nil,
        req_section: nil,
        season: nil,
        sections: [],
        section: nil,
        play: %{season: 1, episode: 1, continue?: false, verb: "Start", label: "S1.E1"},
        episodes: nil,
        watched: MapSet.new(),
        season_counts: %{},
        phase: :idle
      )

    if connected?(socket) do
      # Marks carried in from a friend this account is linked with (Roki.Link).
      if uuid, do: Phoenix.PubSub.subscribe(Roki.PubSub, "link:#{uuid}")
      start_async(socket, :title, fn -> load_title(type, id, uuid) end)
    else
      socket
    end
  end

  # How this device plays: the page tells us (`player` in the socket params, from the browser's
  # own storage). It decides what the sources page does when a release is found.
  defp mode_param(socket),
    do: if(connect_param(socket, "player") == "browser", do: :browser, else: :external)

  defp connect_param(socket, key) do
    if connected?(socket), do: (get_connect_params(socket) || %{})[key]
  end

  defp cached_keys(uuid) do
    hours = SourceCache.hours(Roki.Laev.web_settings(uuid))
    SourceCache.keys(uuid, hours)
  end

  defp rating_state({provider, {:ok, value}}), do: %{state: :ok, value: value, provider: provider}

  defp rating_state({provider, :no_account}),
    do: %{state: :no_account, value: nil, provider: provider}

  defp rating_state(_), do: %{state: :loading, value: nil, provider: :tmdb}

  # Where a film was stopped (seconds), when it is past the beginning — the same position
  # laev resumes from. Series are resumed by episode (the resume record), not by time.
  defp left_at(uuid, %{type: "movie", id: id}) do
    case Roki.Laev.run(uuid, fn -> Laev.Position.saved_position(%{type: "movie", tmdb_id: id}) end) do
      secs when is_integer(secs) and secs >= 30 -> secs
      _ -> nil
    end
  end

  defp left_at(_uuid, _title), do: nil

  defp load_title(type, id, uuid) do
    with {:ok, title} <- Watch.title(type, id, uuid) do
      linked? = uuid && Roki.Laev.connected?(uuid)
      resume = if linked?, do: Roki.Laev.run(uuid, fn -> Laev.Resume.get(type, id) end)
      cached = if linked?, do: cached_keys(uuid), else: MapSet.new()
      lib = if linked?, do: Watch.library(uuid, title)
      secs = if linked?, do: left_at(uuid, title)
      sections = if title.type == "tv", do: Watch.sections(uuid, title), else: []

      play =
        if title.type == "tv" and linked?,
          do: Watch.play_for(uuid, title, sections, resume),
          else: Watch.play_info(sections, resume)

      # An anime is drawn as the season Play is on, not as its first.
      title = Roki.SeasonPosters.for_title(title, play.season, uuid)

      # MyAnimeList rates and lists by season: the one you are watching is the one rated.
      mal = play_mal(title, sections, play)
      rating = if linked?, do: Watch.my_rating(uuid, title, mal)

      {:ok, title, resume, cached, lib, rating, secs, sections, play, mal}
    end
  end

  # Which season a MyAnimeList rating is about, when the show has more than one.
  defp rate_label(sections, mal) when is_integer(mal) and length(sections) > 1 do
    case Enum.find(sections, &(&1.mal == mal)) do
      %{label: label} -> label
      _ -> nil
    end
  end

  defp rate_label(_sections, _mal), do: nil

  defp play_mal(%{anime?: true, type: "tv"}, sections, %{season: s, episode: e})
       when is_integer(s) and is_integer(e) do
    case Watch.locate_section(sections, s, e) do
      {%{mal: mal}, _} when is_integer(mal) -> mal
      {_section, _} when length(sections) > 1 -> :none
      _ -> nil
    end
  end

  defp play_mal(_title, _sections, _play), do: nil

  # The season picked on the episodes page is the one the link and the rating are about.
  defp follow_section(
         %{assigns: %{title: %{anime?: true}, sections: sections}} = socket,
         %{mal: section_mal}
       )
       when length(sections) > 1 do
    mal = section_mal || :none

    if mal == socket.assigns.rate_mal do
      socket
    else
      %{uuid: uuid, title: title, linked?: linked?} = socket.assigns
      socket = assign(socket, :rate_mal, mal)

      if linked? do
        socket
        |> assign(:rating, %{socket.assigns.rating | state: :loading, value: nil})
        |> start_async(:rating_load, fn -> Watch.my_rating(uuid, title, mal) end)
      else
        socket
      end
    end
  end

  defp follow_section(socket, _section), do: socket

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:req_section, params["s"]) |> select()}
  end

  # On the episodes page, settle which season is on screen and load its episodes.
  defp select(%{assigns: %{live_action: :episodes, title: %{}}} = socket) do
    %{resume: resume, req_section: req, sections: sections} = socket.assigns

    wanted =
      find_section(sections, req) || resumed_section(sections, resume) ||
        play_section(sections, socket.assigns[:play]) || List.first(sections)

    cond do
      wanted == nil ->
        socket

      socket.assigns.section == nil or wanted.key != socket.assigns.section.key or
          socket.assigns.episodes == nil ->
        socket
        |> assign(section: wanted, season: wanted.season, episodes: nil)
        |> assign(:title, with_season_poster(socket.assigns.title, wanted.season))
        |> follow_section(wanted)
        |> load_episodes(wanted)

      true ->
        socket
    end
  end

  defp select(socket), do: socket

  # The season on screen on the episodes page gives the poster, when an anime's seasons are kept.
  defp with_season_poster(%{type: "tv", anime?: true} = title, season) when is_integer(season) do
    case Roki.SeasonPosters.stored_poster(title.id, season) do
      nil -> title
      url -> %{title | poster: String.replace(url, "/w342/", "/w500/")}
    end
  end

  defp with_season_poster(title, _season), do: title

  # `?s=` names a section ("2", or "1.2" for the second part of season 1); a bare season number
  # (an old link) is that season's first section.
  defp find_section(_sections, nil), do: nil

  defp find_section(sections, req) do
    Enum.find(sections, &(&1.key == req)) ||
      Enum.find(sections, &(Integer.to_string(&1.season) == req))
  end

  defp resumed_section(sections, %{"season" => s, "episode" => e} = r)
       when is_integer(s) and is_integer(e) do
    with {sec, _local} <- Watch.locate_section(sections, s, r["tmdb_episode"] || e), do: sec
  end

  defp resumed_section(_sections, _resume), do: nil

  # Where Play would go — the newest season with something left to watch — when nothing was left
  # half-played: opening the episodes list lands there, not on season one.
  defp play_section(sections, %{season: s, episode: e}) when is_integer(s) and is_integer(e) do
    with {sec, _local} <- Watch.locate_section(sections, s, e), do: sec
  end

  defp play_section(_sections, _play), do: nil

  defp load_episodes(socket, %{} = sec) do
    %{id: id, uuid: uuid, title: title, linked?: linked?, sections: sections} = socket.assigns

    start_async(socket, :episodes, fn ->
      with {:ok, all} <- Watch.episodes(id, sec.season, uuid) do
        # Only this section's share of the season, numbered from 1 the way the anime list does.
        eps =
          for e <- all,
              e.number > sec.from and (sec.count == nil or e.number <= sec.from + sec.count),
              do: Map.put(e, :local, e.number - sec.from)

        watched =
          if linked?, do: Watch.watched_episodes(uuid, title, sec.season, eps), else: MapSet.new()

        counts = if linked?, do: Watch.section_counts(uuid, title, sections), else: %{}
        {:ok, sec.key, eps, watched, counts}
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

  # Play opens the next page of the flow; nothing starts here.
  @impl true
  def handle_event("play", _params, %{assigns: %{type: "movie", id: id}} = socket),
    do: {:noreply, push_navigate(socket, to: ~p"/sources/movie/#{id}?#{[auto: 1]}")}

  def handle_event("play", _params, %{assigns: %{id: id}} = socket),
    do: {:noreply, push_navigate(socket, to: ~p"/title/tv/#{id}/episodes")}

  # Study mode: remember the languages for this title and open it in the browser player with them.
  def handle_event("study_go", %{"lang" => lang, "subs" => subs} = params, socket) do
    %{uuid: uuid, type: type, id: id} = socket.assigns

    if uuid && socket.assigns.linked? do
      Roki.Study.put(uuid, type, id, lang, subs, params["tr"])

      # The episode asked for in the dialog; failing that, the one after the last finished.
      %{season: season, episode: episode} = study_episode(params["ep"], socket.assigns.study)

      path =
        if type == "movie",
          do: ~p"/watch/movie/#{id}?#{[study: 1]}",
          else: ~p"/watch/tv/#{id}/#{season}/#{episode}?#{[study: 1]}"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  # The Study dialog opened: the episodes to choose from are read now, not with every page.
  def handle_event(
        "study_open",
        _params,
        %{
          assigns: %{
            type: "tv",
            study_eps: nil,
            uuid: uuid,
            title: %{} = title,
            sections: sections
          }
        } = socket
      )
      when is_binary(uuid) do
    {:noreply,
     start_async(socket, :study_eps, fn -> Roki.Watch.study_episodes(uuid, title, sections) end)}
  end

  def handle_event("study_open", _params, socket), do: {:noreply, socket}

  def handle_event("select_season", %{"season" => key}, socket),
    do:
      {:noreply, push_patch(socket, to: ~p"/title/tv/#{socket.assigns.id}/episodes?#{[s: key]}")}

  # Which player this device uses; remembered in the browser, not on the server.
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
    %{uuid: uuid, title: title, lib: lib, solo?: solo?} = socket.assigns
    new = not lib.all_watched?

    {:noreply,
     socket
     |> assign(:lib_busy, true)
     |> start_async(:bulk, fn ->
       Watch.set_series_watched(uuid, title, new, solo: solo?)
       {new, Watch.library(uuid, title)}
     end)}
  end

  def handle_event("toggle_watched", _params, socket), do: {:noreply, socket}

  # The Reviews sheet: what the rating sites and the critics say. Asked for the first time it is
  # opened, then kept for as long as the page is.
  def handle_event("reviews_open", _params, %{assigns: %{reviews: reviews}} = socket)
      when reviews in [nil, :error] do
    %{title: title, uuid: uuid} = socket.assigns

    {:noreply,
     socket
     |> assign(:reviews, :loading)
     |> start_async(:reviews, fn ->
       %{
         scores: Roki.Reviews.scores(title.type, title.id, anime?: title.anime?, uuid: uuid),
         critics: Roki.Reviews.critics(title.type, title.id)
       }
     end)}
  end

  def handle_event("reviews_open", _params, socket), do: {:noreply, socket}

  # Your TMDB rating (0.5–10, half steps): sent to TMDB through laev, shown beside TMDB's average.
  def handle_event("rate", %{"value" => v}, %{assigns: %{rating: %{state: :ok}}} = socket) do
    %{uuid: uuid, title: title, rate_mal: mal} = socket.assigns

    case Float.parse(to_string(v)) do
      {value, _} ->
        {:noreply,
         start_async(socket, :rating, fn ->
           {:rate, Watch.rate(uuid, title, value, mal)}
         end)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("rate", _params, socket), do: {:noreply, socket}

  def handle_event("clear_rating", _params, %{assigns: %{rating: %{state: :ok}}} = socket) do
    %{uuid: uuid, title: title, rate_mal: mal} = socket.assigns

    {:noreply,
     start_async(socket, :rating, fn -> {:clear, Watch.clear_rating(uuid, title, mal)} end)}
  end

  def handle_event("clear_rating", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_saved", _params, socket) do
    %{uuid: uuid, title: title, lib: lib} = socket.assigns
    saved? = Watch.toggle_saved(uuid, title) == :added
    {:noreply, assign(socket, :lib, %{lib | saved?: saved?})}
  end

  # "Remove watch progress" in the ⋯ menu: what was played and where it was left, so the title leaves
  # the Watchlist and History. The page is opened again, so everything on it that came from that
  # (Continue, the episode marks, the buttons) is read afresh.
  def handle_event("forget_progress", _params, %{assigns: %{uuid: uuid, title: title}} = socket)
      when is_binary(uuid) do
    Watch.forget_progress(uuid, title.type, title.id)
    {:noreply, push_navigate(socket, to: ~p"/title/#{title.type}/#{title.id}")}
  end

  def handle_event("forget_progress", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_hold", _params, socket) do
    %{uuid: uuid, title: title, lib: lib} = socket.assigns
    held? = Watch.toggle_hold(uuid, title) == :held
    {:noreply, assign(socket, :lib, %{lib | held?: held?})}
  end

  def handle_event("toggle_episode", %{"season" => s, "episode" => e}, socket) do
    %{uuid: uuid, title: title, watched: watched, solo?: solo?} = socket.assigns

    with season when is_integer(season) <- to_int(s), ep when is_integer(ep) <- to_int(e) do
      new = not MapSet.member?(watched, ep)
      Watch.set_watched(uuid, title, season, ep, new, solo: solo?)

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
    %{uuid: uuid, title: title, season: season, watched: watched, solo?: solo?} = socket.assigns
    out = for e <- eps, e.aired?, do: e.number
    all? = out != [] and Enum.all?(out, &MapSet.member?(watched, &1))
    Watch.set_many_watched(uuid, title, Enum.map(out, &{season, &1}), not all?, solo: solo?)

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

  # ── what comes back from the tasks ─────────────────────────────────

  @impl true
  def handle_async(
        :title,
        {:ok, {:ok, title, resume, cached, lib, rating, secs, sections, play, mal}},
        socket
      ) do
    # What Play would start is looked for now, while the page is read.
    if socket.assigns.linked? do
      case title.type do
        "movie" -> Roki.Watch.Prefetch.warm(socket.assigns.uuid, title)
        _ -> Roki.Watch.Prefetch.warm(socket.assigns.uuid, title, play.season, play.episode)
      end
    end

    socket =
      assign(socket,
        title: title,
        sections: sections,
        play: play,
        resume: resume,
        resume_secs: secs,
        cached: cached,
        lib: lib || socket.assigns.lib,
        rating: rating_state(rating),
        rate_mal: mal,
        page_title: title.title
      )

    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> tap(fn _ ->
       Task.start(fn -> Roki.Social.remember_title(title.type, title.id, title.title) end)
     end)
     |> start_async(:similar, fn ->
       # What this person has watched, saved and rated of them, worked out alongside.
       with {:ok, cards} <- Roki.Similar.for_title(uuid, title.type, title.id) do
         {:ok, Roki.Laev.annotate(uuid, cards), Roki.Laev.seen_keys(uuid, cards)}
       end
     end)
     |> start_async(:study, fn -> if uuid, do: study_choice(uuid, title, sections) end)
     |> start_async(:trailer, fn -> Roki.Trailers.key(title.type, title.id, uuid) end)
     |> start_async(:credits, fn -> Roki.Credits.for_title(title.type, title.id, uuid) end)
     |> select()}
  end

  def handle_async(:similar, {:ok, {:ok, cards, seen}}, socket),
    do: {:noreply, assign(socket, similar: cards, similar_seen: seen)}

  def handle_async(:similar, _other, socket), do: {:noreply, socket}

  # TMDB lists a trailer's YouTube address; nothing here means the page simply has no button.
  def handle_async(:trailer, {:ok, key}, socket) when is_binary(key),
    do: {:noreply, assign(socket, :trailer, key)}

  def handle_async(:trailer, _other, socket), do: {:noreply, socket}

  def handle_async(:credits, {:ok, %{} = credits}, socket),
    do: {:noreply, assign(socket, :credits, credits)}

  def handle_async(:credits, _other, socket), do: {:noreply, socket}

  def handle_async(:study, {:ok, %{} = choice}, socket),
    do: {:noreply, assign(socket, :study, choice)}

  def handle_async(:study, _other, socket), do: {:noreply, socket}

  def handle_async(:study_eps, {:ok, groups}, socket) when is_list(groups),
    do: {:noreply, assign(socket, :study_eps, groups)}

  def handle_async(:study_eps, _other, socket), do: {:noreply, socket}

  def handle_async(:title, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :title_error, reason || true)}

  def handle_async(:title, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :title_error, reason)}

  def handle_async(:reviews, {:ok, %{} = reviews}, socket),
    do: {:noreply, assign(socket, :reviews, reviews)}

  def handle_async(:reviews, _other, socket), do: {:noreply, assign(socket, :reviews, :error)}

  def handle_async(:rating_load, {:ok, rating}, socket),
    do: {:noreply, assign(socket, :rating, rating_state(rating))}

  def handle_async(:rating_load, _other, socket),
    do: {:noreply, assign(socket, :rating, %{state: :loading, value: nil, provider: :tmdb})}

  # Rated is watched (Roki.Watch.rate/4): the watched state on the page is read again.
  def handle_async(:rating, {:ok, {:rate, {:ok, value}}}, socket) do
    %{uuid: uuid, title: title} = socket.assigns

    {:noreply,
     socket
     |> assign(rating: %{socket.assigns.rating | value: value}, rating_error: nil)
     |> start_async(:lib_reload, fn -> Watch.library(uuid, title) end)}
  end

  def handle_async(:lib_reload, {:ok, %{} = lib}, socket),
    do: {:noreply, assign(socket, :lib, lib)}

  def handle_async(:lib_reload, _other, socket), do: {:noreply, socket}

  def handle_async(:rating, {:ok, {:clear, :ok}}, socket),
    do:
      {:noreply, assign(socket, rating: %{socket.assigns.rating | value: nil}, rating_error: nil)}

  def handle_async(:rating, _other, socket),
    do:
      {:noreply,
       assign(
         socket,
         :rating_error,
         "#{provider_name(socket.assigns.rating.provider)} did not take that. Try again."
       )}

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

  def handle_async(:episodes, {:ok, {:ok, key, eps, watched, counts}}, socket) do
    if socket.assigns.section && key == socket.assigns.section.key,
      do: {:noreply, assign(socket, episodes: eps, watched: watched, season_counts: counts)},
      else: {:noreply, socket}
  end

  def handle_async(:episodes, _other, socket), do: {:noreply, assign(socket, episodes: [])}

  # The link panel (RokiWeb.LinkProgress), and marks carried in from a friend.
  @impl true
  def handle_info({:link_solo, solo?}, socket), do: {:noreply, assign(socket, :solo?, solo?)}
  def handle_info(:link_reload, socket), do: {:noreply, reload_marks(socket)}

  def handle_info({:link_state, state}, socket),
    do: {:noreply, assign(socket, :link_state, state)}

  def handle_info({:link_marked, id}, %{assigns: %{id: id}} = socket),
    do: {:noreply, reload_marks(socket)}

  def handle_info(_other, socket), do: {:noreply, socket}

  defp reload_marks(%{assigns: %{live_action: :episodes, section: %{} = sec}} = socket),
    do: load_episodes(socket, sec)

  defp reload_marks(socket), do: socket

  # ── view ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    # The show page runs edge to edge once its title is in; before that (and on the episodes page)
    # it has the padded column it always had.
    assigns =
      assign(assigns, :full?, assigns.live_action in [:show, :episodes] and assigns.title != nil)

    ~H"""
    <%!-- Flush: this page lays itself out. The hero runs to the edges of the window under a header
          that floats over it, on a phone as on a wide screen; the sections below carry their own
          gutters. --%>
    <Layouts.app
      socket={@socket}
      flash={@flash}
      flush
      bleed={@full?}
      overlay={@full?}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/title/#{@type}/#{@id}"}
    >
      <div class={if @full?, do: "", else: "px-4 py-8 sm:px-6 lg:px-8"}>
        <div class={["mx-auto space-y-4", if(@full?, do: "max-w-none", else: "max-w-6xl")]}>
          <p :if={@title_error} class="alert alert-error">
            {if @uuid,
              do: "Couldn't load this title just now. Try again in a minute.",
              else: "Log in to open titles — they are read with your own TMDB key."}
          </p>

          <div :if={@title == nil and @title_error == nil} class="space-y-4" aria-busy="true">
            <div class="skeleton h-64 w-full rounded-box"></div>
            <div class="skeleton h-8 w-1/3 rounded"></div>
          </div>

          <div :if={@title && @live_action == :show} class="space-y-8">
            <.rate_sheet
              :if={@linked?}
              title={@title}
              rating={@rating}
              error={@rating_error}
              label={rate_label(@sections, @rate_mal)}
            />

            <.link_sheet :if={@linked? and @title.type == "tv" and @uuid} uuid={@uuid} title={@title} />
            <.trailer_sheet :if={@trailer} key={@trailer} title={@title} />
            <.reviews_sheet title={@title} reviews={@reviews} />

            <.cinema_hero
              mal={@rate_mal}
              link_state={@link_state}
              trailer={@trailer}
              study={@study}
              rating={@rating}
              title={@title}
              play={@play}
              resume={@resume}
              resume_secs={@resume_secs}
              phase={@phase}
              season={@season}
              mode={@mode}
              linked?={@linked?}
              lib={@lib}
              lib_busy={@lib_busy}
              cached?={@type == "movie" and MapSet.member?(@cached, {"movie", @id, nil, nil})}
            />

            <.study_sheet :if={@linked? and @study} title={@title} study={@study} eps={@study_eps} />

            <div class="px-4 sm:px-6 lg:px-12 xl:px-16">
              <.access_notice uuid={@uuid} linked?={@linked?} />
            </div>

            <.facts_panel title={@title} credits={@credits} />
            <.cast_row cast={@credits.cast} />

            <%!-- The comments come right after the cast: they matter more than more like this. --%>
            <div :if={@title.type in ["movie", "tv"]} class="px-4 sm:px-6 lg:px-12 xl:px-16">
              <div>
                <.title_comments
                  id="title-comments"
                  title={@title}
                  user={assigns[:phoenix_kit_current_user]}
                />
              </div>
            </div>

            <%!-- Last. --%>
            <.similar_row
              items={@similar}
              seen={@similar_seen}
              cached_titles={@cached_titles}
              signed_in?={@uuid != nil}
            />

            <div class="h-12" aria-hidden="true"></div>
          </div>

          <div :if={@title && @live_action == :episodes}>
            <.episodes_header
              title={@title}
              play={@play}
              resume={@resume}
              linked?={@linked?}
              lib={@lib}
              mal={@rate_mal}
            />
            <div class="space-y-6 px-4 pb-12 pt-6 sm:px-6 lg:px-12 xl:px-16">
              <.rate_sheet
                :if={@linked? and @rating.provider == :mal}
                title={@title}
                rating={@rating}
                error={@rating_error}
                label={rate_label(@sections, @rate_mal)}
              />
              <.access_notice uuid={@uuid} linked?={@linked?} />

              <.live_component
                :if={@linked? and @uuid}
                module={RokiWeb.LinkProgress}
                id="link-progress"
                uuid={@uuid}
                title={@title}
                rev={:erlang.phash2({@season, @watched})}
              />

              <.episodes
                title={@title}
                season={@season}
                sections={@sections}
                section={@section}
                episodes={@episodes}
                watched={@watched}
                season_counts={@season_counts}
                cached={@cached}
                title_id={@id}
                can_play?={@linked?}
                rating={@rating}
              />
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :map, required: true
  attr :resume, :any, default: nil
  attr :play, :map, required: true
  attr :linked?, :boolean, default: false
  attr :lib, :map, required: true
  attr :mal, :any, default: nil

  # The top of the episodes page: where you are, and a way back to the title — a banner like the
  # title page's, smaller.
  defp episodes_header(assigns) do
    ~H"""
    <section class="relative z-20 flex min-h-[clamp(18rem,40svh,26rem)] flex-col justify-end text-white">
      <div class="absolute inset-0 -z-10 overflow-hidden bg-neutral-900">
        <img
          :if={@title.backdrop}
          src={hero_backdrop(@title.backdrop)}
          alt=""
          class="h-full w-full object-cover opacity-70"
        />
        <div class="absolute inset-0 bg-gradient-to-r from-black/85 via-black/50 to-black/10"></div>
        <div class="absolute inset-0 bg-gradient-to-t from-black/80 via-transparent to-black/50">
        </div>
      </div>

      <div class="absolute right-4 top-16 z-20 sm:right-6 lg:right-12 lg:top-20 xl:right-16">
        <.more_menu
          id="more-menu-eps"
          title={@title}
          linked?={@linked?}
          lib={@lib}
          mal={@mal}
          button_class="h-11 min-h-0 w-11 border border-white/25 bg-black/35 text-white backdrop-blur-md hover:border-white/60 hover:bg-black/55"
        />
      </div>

      <div class="flex flex-col gap-5 px-4 pb-8 pt-28 sm:px-6 lg:px-12 xl:px-16">
        <div class="flex items-end gap-5">
          <img
            :if={@title.poster}
            src={Roki.Images.local(@title.poster)}
            alt={@title.title}
            class="hidden h-44 w-auto shrink-0 rounded-xl shadow-2xl ring-1 ring-white/15 sm:block"
          />
          <div class="min-w-0 flex-1 space-y-3">
            <.link
              navigate={~p"/title/tv/#{@title.id}"}
              class="inline-flex h-9 items-center gap-1.5 rounded-full border border-white/25 bg-black/30 px-3.5 text-sm font-medium backdrop-blur-md transition hover:border-white/60 hover:bg-black/45"
            >
              <.icon name="hero-arrow-left-micro" class="h-4 w-4" /> Back to the title
            </.link>
            <p class="text-xs font-semibold uppercase tracking-[0.25em] text-white/70">Episodes</p>
            <h1 class="text-4xl font-bold leading-[1.04] tracking-tight drop-shadow-lg sm:text-5xl xl:text-6xl">
              {@title.title}
            </h1>
            <p class="hidden text-base text-white/75 sm:block">{meta(@title)}</p>
            <p class="text-sm text-white/75 sm:hidden">
              {[@title.year, seasons_text(@title)] |> Enum.filter(& &1) |> Enum.join(" · ")}
            </p>
          </div>
        </div>

        <div :if={@play.continue?} class="flex flex-wrap gap-3">
          <.link
            navigate={~p"/sources/tv/#{@title.id}/#{@play.season}/#{@play.episode}?#{[auto: 1]}"}
            class="btn btn-primary btn-lg h-14 min-h-0 gap-2 rounded-full px-8 text-xl shadow-md max-sm:w-full"
          >
            <.icon name="hero-play-solid" class="h-6 w-6" /> {@play.verb} {@play.label}
          </.link>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :map, required: true
  attr :user, :any, default: nil

  # What people here have said about the title: comments, a thread of replies. One thread for the
  # title, the same for everyone. Plain text, so it needs no editor script.
  defp title_comments(assigns) do
    ~H"""
    <section class="space-y-3" aria-label="Comments">
      <.live_component
        module={PhoenixKitComments.Web.CommentsComponent}
        id={@id}
        resource_type="title"
        resource_uuid={Roki.Social.title_uuid(@title.type, @title.id)}
        current_user={@user}
        rich_text={false}
      />
    </section>
    """
  end

  # ── the wide-screen page: a hero the picture runs through, then rows ────────────────

  # Where each thing is drawn from: the film's own backdrop at its largest (the hero is the width of
  # the window), and what kind of title it is, in a word.
  defp hero_backdrop(nil), do: nil

  defp hero_backdrop(url),
    do: Roki.Images.local(String.replace(url, "/w1280/", "/original/"))

  # The page of this kind of title, filtered by one of its genres; nil when that kind has no such genre.
  defp genre_path(title, name) do
    kind = browse_kind(title)

    case Roki.Genres.slug_for_name(name, kind) do
      nil -> nil
      slug -> "/#{kind}?genre=#{slug}"
    end
  end

  defp browse_kind(%{anime?: true}), do: :anime
  defp browse_kind(%{type: "tv"}), do: :shows
  defp browse_kind(_), do: :movies

  defp kind_label(%{anime?: true}), do: "Anime"
  defp kind_label(%{type: "movie"}), do: "Film"
  defp kind_label(_), do: "Series"

  defp release_date(nil), do: nil

  defp release_date(iso) do
    case Date.from_iso8601(iso) do
      {:ok, d} ->
        "#{Calendar.strftime(d, "%-d %b %Y")} (#{how_long(Date.diff(Date.utc_today(), d))})"

      _ ->
        nil
    end
  end

  # "233 days ago", as the card over a poster says it; a title not out yet says when it will be.
  defp how_long(0), do: "today"
  defp how_long(1), do: "yesterday"
  defp how_long(-1), do: "tomorrow"
  defp how_long(days) when days > 1, do: "#{group_digits(days)} days ago"
  defp how_long(days), do: "in #{group_digits(-days)} days"

  defp group_digits(n),
    do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")

  attr :cached?, :boolean, default: false
  attr :title, :map, required: true
  attr :resume, :any, default: nil
  attr :resume_secs, :any, default: nil

  attr :play, :map,
    default: %{season: 1, episode: 1, continue?: false, verb: "Start", label: "S1.E1"}

  attr :phase, :any, required: true
  attr :season, :any, default: nil
  attr :mode, :atom, required: true
  attr :linked?, :boolean, default: false
  attr :lib, :map, required: true
  attr :lib_busy, :boolean, default: false
  attr :rating, :map, required: true
  attr :mal, :any, default: nil
  attr :link_state, :any, default: :none
  attr :trailer, :any, default: nil
  attr :study, :map, default: nil

  # The title at the top of the page on a wide screen. The backdrop runs edge to edge under the
  # floating header; after a couple of seconds the trailer plays in its place, muted, with
  # controls in the corner (`HeroTrailer`). The words are over it on the left, the actions are
  # round glass buttons — the same look as the cards on the home page.
  defp cinema_hero(assigns) do
    assigns =
      assign(assigns,
        backdrop: hero_backdrop(assigns.title.backdrop),
        kind: kind_label(assigns.title)
      )

    ~H"""
    <section
      id="hero"
      phx-hook="HeroTrailer"
      data-hero
      data-key={@trailer}
      class="group/hero relative isolate flex min-h-[clamp(34rem,86svh,54rem)] flex-col justify-end overflow-hidden bg-neutral-900 text-white lg:min-h-[clamp(34rem,80svh,54rem)]"
      aria-label={@title.title}
    >
      <img
        :if={@backdrop}
        src={@backdrop}
        alt=""
        class="absolute inset-0 -z-10 h-full w-full object-cover"
      />
      <%!-- The trailer's player is put here by the hook; the page never touches it again. --%>
      <div
        id="hero-video"
        data-hero-video
        phx-update="ignore"
        class="absolute inset-0 -z-10 [container-type:size]"
      >
      </div>
      <div
        data-hero-fade
        class="absolute inset-0 -z-10 bg-gradient-to-r from-black/85 via-black/45 to-transparent"
      >
      </div>
      <div
        data-hero-fade
        class="absolute inset-0 -z-10 bg-gradient-to-t from-black/75 via-transparent to-black/45"
      >
      </div>

      <div
        class="absolute right-4 top-16 z-20 sm:right-6 lg:right-12 lg:top-20 xl:right-16"
        data-hero-content
      >
        <.more_menu
          id="more-menu-cinema"
          title={@title}
          linked?={@linked?}
          lib={@lib}
          mal={@mal}
          button_class="h-11 min-h-0 w-11 border border-white/25 bg-black/35 text-white backdrop-blur-md hover:border-white/60 hover:bg-black/55"
        />
      </div>

      <div
        data-hero-content
        class="relative z-10 flex max-w-4xl flex-col gap-3 px-4 pb-7 pt-32 sm:px-6 lg:gap-4 lg:px-12 lg:pb-14 xl:px-16"
      >
        <p class="text-xs font-semibold uppercase tracking-[0.25em] text-white/70">{@kind}</p>
        <h1 class="text-4xl font-bold leading-[1.04] tracking-tight drop-shadow-lg sm:text-5xl xl:text-7xl">
          {@title.title}
        </h1>

        <div class="flex flex-wrap items-center gap-x-3 gap-y-2 text-sm text-white/85">
          <button
            :if={is_number(@title.vote) and @title.vote > 0}
            type="button"
            phx-click={JS.show(to: "#reviews-sheet", display: "flex") |> JS.push("reviews_open")}
            class="flex items-center gap-1 rounded-md bg-black/50 px-2 py-1 font-semibold backdrop-blur transition hover:bg-black/70"
            title="TMDB's score — every service's, and what the critics said"
            aria-label="Reviews and scores"
          >
            <span class="text-amber-300" aria-hidden="true">★</span>{avg_text(@title)}
            <.icon name="hero-chevron-down-micro" class="h-3.5 w-3.5 text-white/60" />
          </button>
          <span :if={@title.year}>{@title.year}</span>
          <span :if={@title.minutes}>{@title.minutes} min</span>
          <span :if={seasons_text(@title)}>{seasons_text(@title)}</span>
          <span :if={episodes_text(@title)}>{episodes_text(@title)}</span>
          <%!-- A genre leads to that kind's page, filtered by it: more of the same. --%>
          <%= for g <- Enum.take(@title.genres, 3) do %>
            <.link
              :if={genre_path(@title, g)}
              navigate={genre_path(@title, g)}
              class="rounded-full border border-white/30 px-3 py-0.5 text-white/80 transition hover:border-white/70 hover:bg-white/15 hover:text-white"
            >
              {g}
            </.link>
            <span
              :if={!genre_path(@title, g)}
              class="rounded-full border border-white/30 px-3 py-0.5 text-white/80"
            >
              {g}
            </span>
          <% end %>
        </div>

        <p :if={@title.tagline} class="italic text-white/65">{@title.tagline}</p>

        <div class="flex flex-wrap items-center gap-2 pt-3 sm:gap-3">
          <.play_button
            title={@title}
            play={@play}
            resume={@resume}
            resume_secs={@resume_secs}
            busy?={match?({:working, _}, @phase)}
            cached?={@cached?}
            class="h-14 w-full rounded-full text-xl sm:w-auto sm:min-w-[14rem]"
          />
          <%!-- On a phone the buttons under Start are two capsules side by side: ways to watch it, and
                what you do with it. From `sm` up the wrappers vanish and they are one row, as before. --%>
          <div class="flex items-center justify-around gap-1 max-sm:min-w-0 max-sm:flex-1 max-sm:rounded-full max-sm:border max-sm:border-white/20 max-sm:bg-black/25 max-sm:p-1.5 max-sm:backdrop-blur-md sm:contents">
            <.glass_btn
              :if={@trailer}
              click={open_trailer()}
              icon="hero-play-circle"
              label="Watch the trailer"
              text="Trailer"
              text_class="max-sm:hidden"
              class="lg:hidden"
            />
            <.glass_btn
              :if={@linked? and @title.type == "movie"}
              href={~p"/sources/movie/#{@title.id}"}
              icon="hero-queue-list"
              label="Choose which release to play"
            />
            <.glass_btn
              :if={@linked? and @study}
              click={JS.show(to: "#study-sheet", display: "flex") |> JS.push("study_open")}
              icon="hero-academic-cap"
              label="Study: watch in languages you choose"
            />
          </div>
          <%!-- Your record of it, apart from watching it: a gap sets it off from the buttons before. --%>
          <div
            :if={@linked?}
            class="flex items-center justify-around gap-1 max-sm:min-w-0 max-sm:flex-1 max-sm:rounded-full max-sm:border max-sm:border-white/20 max-sm:bg-black/25 max-sm:p-1.5 max-sm:backdrop-blur-md sm:ml-3 sm:gap-3 lg:ml-5"
          >
            <.glass_btn
              :if={@linked?}
              click="toggle_saved"
              icon={if @lib.saved?, do: "hero-check", else: "hero-plus"}
              on={@lib.saved?}
              label={if @lib.saved?, do: "Saved for later (click to remove)", else: "Save for later"}
            />
            <.glass_btn
              :if={@linked?}
              click="toggle_watched"
              icon={
                if watched_state?(@title, @lib),
                  do: "hero-eye-solid",
                  else: "hero-eye"
              }
              on={watched_state?(@title, @lib)}
              tone={:success}
              busy={@lib_busy}
              label={
                if watched_state?(@title, @lib),
                  do: "#{watched_label(@title, @lib)} (click to mark as not watched)",
                  else: watched_label(@title, @lib)
              }
            />
            <.glass_btn
              :if={@linked?}
              click={JS.show(to: "#rate-sheet", display: "flex")}
              icon={if @rating.value, do: "hero-star-solid", else: "hero-star"}
              on={@rating.value != nil}
              tone={:amber}
              text={if @rating.value, do: fmt_rating(@rating.value)}
              label={if @rating.value, do: "Your rating: click to change it", else: "Rate it"}
            />
            <.glass_btn
              :if={@linked? and @title.type == "tv"}
              click={JS.show(to: "#link-sheet", display: "flex")}
              icon={if @link_state in [:none, :pending], do: "hero-link", else: "hero-link-solid"}
              on={@link_state not in [:none, :pending]}
              label={link_title(@link_state)}
            />
          </div>
        </div>
      </div>

      <%!-- Where Play opens it, and the trailer's controls: pause (it plays once, it does not loop),
            sound, full screen. --%>
      <div class="relative z-20 flex items-center gap-3 px-4 sm:px-6 max-lg:hidden lg:absolute lg:bottom-14 lg:right-12 lg:h-14 lg:justify-end lg:p-0 xl:right-16">
        <button
          :if={@trailer}
          type="button"
          data-hero-ctl="play"
          class={hero_ctl()}
          title="Play or pause the trailer"
          aria-label="Play or pause the trailer"
        >
          <span class="flex group-data-[hero-playing=true]/hero:hidden">
            <.icon name="hero-play-solid" class="h-5 w-5" />
          </span>
          <span class="hidden group-data-[hero-playing=true]/hero:flex">
            <.icon name="hero-pause-solid" class="h-5 w-5" />
          </span>
        </button>
        <button
          :if={@trailer}
          type="button"
          data-hero-ctl="mute"
          class={hero_ctl()}
          title="Sound on or off"
          aria-label="Sound on or off"
        >
          <span class="flex group-data-[hero-muted=false]/hero:hidden">
            <.icon name="hero-speaker-x-mark" class="h-5 w-5" />
          </span>
          <span class="hidden group-data-[hero-muted=false]/hero:flex">
            <.icon name="hero-speaker-wave" class="h-5 w-5" />
          </span>
        </button>
        <button
          :if={@trailer}
          type="button"
          data-hero-ctl="full"
          class={hero_ctl()}
          title="Full screen"
          aria-label="Full screen"
        >
          <.icon name="hero-arrows-pointing-out" class="h-5 w-5" />
        </button>
      </div>
    </section>
    """
  end

  defp hero_ctl,
    do:
      "flex h-11 w-11 items-center justify-center rounded-full border border-white/25 bg-black/35 text-white backdrop-blur-md transition hover:border-white/60 hover:bg-black/55 max-lg:hidden"

  attr :click, :any, default: nil
  attr :href, :any, default: nil
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :on, :boolean, default: false
  attr :busy, :boolean, default: false
  attr :text, :string, default: nil
  attr :text_class, :string, default: nil
  attr :tone, :atom, default: :white
  attr :class, :string, default: nil

  # A round glass button for an action on the hero: an icon, the words as its tooltip, lit when it
  # is on. (A score or a name rides beside the icon when there is one.)
  defp glass_btn(assigns) do
    ~H"""
    <.link
      :if={@href}
      navigate={@href}
      class={[glass_class(@on, @tone, @text), @class]}
      title={@label}
      aria-label={@label}
    >
      <.icon name={@icon} class="h-5 w-5" />
    </.link>
    <button
      :if={!@href}
      type="button"
      phx-click={@click}
      disabled={@busy}
      class={[glass_class(@on, @tone, @text), @class]}
      title={@label}
      aria-label={@label}
    >
      <span :if={@busy} class="loading loading-spinner loading-sm"></span>
      <.icon :if={!@busy} name={@icon} class="h-5 w-5" />
      <span :if={@text} class={["max-w-40 truncate text-sm font-semibold", @text_class]}>
        {@text}
      </span>
    </button>
    """
  end

  defp glass_class(on, tone, text) do
    [
      "flex h-10 items-center justify-center gap-1.5 rounded-full border sm:h-12 text-white backdrop-blur-md transition",
      if(text, do: "px-3 sm:px-4", else: "w-10 sm:w-12"),
      cond do
        on and tone == :success ->
          "border-emerald-300/70 bg-emerald-500/40 hover:bg-emerald-500/55"

        on and tone == :amber ->
          "border-amber-300/70 bg-amber-400/30 hover:bg-amber-400/45"

        on ->
          "border-white/70 bg-white/25 hover:bg-white/35"

        true ->
          "border-white/25 bg-white/10 hover:border-white/60 hover:bg-white/20"
      end
    ]
  end

  attr :title, :map, required: true
  attr :credits, :map, required: true

  # What the hero has no room for: the whole story and the facts, the poster beside them.
  defp facts_panel(assigns) do
    t = assigns.title
    c = assigns.credits

    facts =
      [
        {"Status", t[:status]},
        {if(t.type == "movie", do: "Released", else: "First aired"), release_date(t[:date])},
        {"Runtime", t.minutes && "#{t.minutes} min"},
        {"Seasons", seasons_text(t)},
        {"Newest season", newest_season(t)},
        {"Directed by", join(c.directors)},
        {"Written by", join(c.writers)},
        {"Language", join(t[:spoken]) || t[:language]},
        {"Country", join(t[:countries])},
        {if(t.type == "tv", do: "Network", else: "Studio"),
         join(Enum.take((t.type == "tv" && t[:networks]) || t[:studios] || [], 3))}
      ]
      |> Enum.filter(fn {_label, value} -> is_binary(value) and value != "" end)

    assigns = assign(assigns, facts: facts)

    ~H"""
    <section id="details" class="scroll-mt-20 px-4 sm:px-6 lg:px-12 xl:px-16" aria-label="Details">
      <div class="flex gap-8 rounded-3xl border border-base-300/70 bg-base-100/70 p-5 shadow-sm backdrop-blur sm:p-6 lg:p-8">
        <img
          :if={@title.poster}
          src={Roki.Images.local(@title.poster)}
          alt={@title.title}
          loading="lazy"
          class="hidden aspect-[2/3] w-40 shrink-0 self-start rounded-2xl bg-base-300 object-cover shadow-xl ring-1 ring-black/10 xl:block xl:w-48"
        />
        <div class="min-w-0 flex-1 space-y-6">
          <div class="space-y-2">
            <h2 class="text-xl font-semibold tracking-tight">About</h2>
            <p :if={@title.overview} class="max-w-3xl leading-relaxed text-base-content/80">
              {@title.overview}
            </p>
          </div>
          <dl class="grid grid-cols-2 gap-x-6 gap-y-5 text-sm lg:gap-x-8 xl:grid-cols-3">
            <div :for={{label, value} <- @facts} class="min-w-0">
              <dt class="text-xs font-medium uppercase tracking-wider text-base-content/50">
                {label}
              </dt>
              <dd class="mt-0.5 font-medium">{value}</dd>
            </div>
          </dl>
          <div class="flex flex-wrap gap-2 text-sm">
            <a
              :if={@title[:imdb_id]}
              href={"https://www.imdb.com/title/#{@title.imdb_id}/"}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-sm rounded-full"
            >
              IMDb <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" />
            </a>
            <a
              href={"https://www.themoviedb.org/#{@title.type}/#{@title.id}"}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-sm rounded-full"
            >
              TMDB <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" />
            </a>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp join(nil), do: nil
  defp join([]), do: nil
  defp join(list) when is_list(list), do: Enum.join(list, ", ")
  defp join(other), do: other

  attr :id, :string, required: true
  attr :title, :string, required: true

  attr :cards?, :boolean,
    default: false,
    doc: "its items open into cards on hover (the home page's)"

  attr :class, :string, default: nil
  slot :inner_block, required: true

  # A row that scrolls sideways, with the chevron on the side the pointer is over (`ShelfRow`):
  # the home page's rows, for the cast and for more like this.
  defp scroll_row(assigns) do
    ~H"""
    <section
      id={@id}
      phx-hook="ShelfRow"
      data-start="true"
      data-end="false"
      class={["group/row", @class]}
      aria-label={@title}
    >
      <h2 class="mb-3 px-4 text-2xl font-semibold tracking-tight sm:px-6 lg:px-12 xl:px-16">
        {@title}
      </h2>
      <div class="relative [--card-w:clamp(9rem,11.2vw,14rem)]">
        <button
          type="button"
          data-row-prev
          aria-label={"Scroll #{@title} back"}
          class={[
            "absolute left-0 justify-start rounded-l-xl bg-gradient-to-r pl-2 z-30 hidden w-14 items-center from-black/60 via-black/25 to-transparent text-white opacity-0 transition hover:from-black/75 max-lg:!hidden group-data-[start=false]/row:flex group-hover/row:opacity-[calc(0.3_+_0.7_*_var(--near-l,0))] hover:opacity-100 focus-visible:opacity-100",
            if(@cards?, do: "top-4 h-[calc(var(--card-w)*1.5)]", else: "inset-y-0")
          ]}
        >
          <.icon name="hero-chevron-left" class="h-10 w-10 drop-shadow" />
        </button>
        <button
          type="button"
          data-row-next
          aria-label={"Scroll #{@title} forward"}
          class={[
            "absolute right-0 justify-end rounded-r-xl bg-gradient-to-l pr-2 z-30 hidden w-14 items-center from-black/60 via-black/25 to-transparent text-white opacity-0 transition hover:from-black/75 max-lg:!hidden group-data-[end=false]/row:flex group-hover/row:opacity-[calc(0.3_+_0.7_*_var(--near-r,0))] hover:opacity-100 focus-visible:opacity-100",
            if(@cards?, do: "top-4 h-[calc(var(--card-w)*1.5)]", else: "inset-y-0")
          ]}
        >
          <.icon name="hero-chevron-right" class="h-10 w-10 drop-shadow" />
        </button>
        <ul
          data-row-scroller
          data-card-row={@cards?}
          class={[
            "flex snap-x scroll-px-4 gap-3 overflow-x-auto scroll-smooth px-4 [--card-w:clamp(9rem,11.2vw,14rem)] [scrollbar-width:none] sm:scroll-px-6 sm:px-6 lg:scroll-px-12 lg:gap-4 lg:px-12 xl:scroll-px-16 xl:px-16",
            if(@cards?, do: "-mb-[3.25rem] -mt-3 pb-16 pt-4", else: "pb-3 pt-1")
          ]}
        >
          {render_slot(@inner_block)}
        </ul>
      </div>
    </section>
    """
  end

  attr :cast, :list, required: true

  defp cast_row(assigns) do
    ~H"""
    <.scroll_row :if={@cast != []} id="row-cast" title="Cast">
      <li :for={p <- @cast} class="w-32 shrink-0 snap-start text-center xl:w-36">
        <div class="mx-auto flex h-28 w-28 items-center justify-center overflow-hidden rounded-full bg-base-300 ring-1 ring-base-content/10 xl:h-32 xl:w-32">
          <img
            :if={p.photo}
            src={Roki.Images.local(p.photo)}
            alt=""
            loading="lazy"
            class="h-full w-full object-cover"
          />
          <span :if={!p.photo} class="text-2xl font-semibold text-base-content/40">
            {p.name |> String.first()}
          </span>
        </div>
        <p class="mt-2 truncate text-sm font-medium" title={p.name}>{p.name}</p>
        <p :if={p.character} class="truncate text-xs text-base-content/60" title={p.character}>
          {p.character}
        </p>
      </li>
    </.scroll_row>
    """
  end

  attr :items, :list, required: true
  attr :seen, :any, required: true
  attr :cached_titles, :any, default: nil
  attr :signed_in?, :boolean, default: false

  defp similar_row(assigns) do
    ~H"""
    <.scroll_row
      :if={@items != []}
      id="row-similar"
      title="More like this"
      cards?
    >
      <RokiWeb.FeaturedLive.shelf_card
        :for={i <- Enum.take(@items, 20)}
        kind={:similar}
        item={i}
        seen={MapSet.member?(@seen, {i.type, i.id})}
        cached_titles={@cached_titles}
        upcoming={%{}}
        signed_in?={@signed_in?}
      />
    </.scroll_row>
    """
  end

  defp avg_text(%{vote: v}) when is_number(v) and v > 0, do: fmt_rating(Float.round(v * 1.0, 1))
  defp avg_text(_), do: "–"

  # 8.0 → "8", 8.5 → "8.5"
  defp provider_name(:mal), do: "MyAnimeList"
  defp provider_name(:roki), do: "Roki"
  defp provider_name(_), do: "TMDB"

  # The languages the Study dialog starts on: the ones remembered for this title, else the
  # account's own settings.
  defp study_choice(uuid, title, sections) do
    langs =
      case Roki.Study.get(uuid, title.type, title.id) do
        %{"lang" => lang, "subs" => subs} = prefs ->
          %{lang: lang, subs: subs, tr: Roki.Study.translate(uuid, prefs)}

        nil ->
          Roki.Laev.run(uuid, fn ->
            %{lang: Laev.Config.lang(), subs: Laev.Config.subs_lang() || "off"}
          end)
          |> Map.put(:tr, Roki.Study.account_language(uuid))
      end

    # A series starts at the episode after the last one finished, whatever the player last
    # remembered; the dialog can pick another.
    if title.type == "tv",
      do: Map.put(langs, :start, Roki.Watch.study_start(uuid, title, sections)),
      else: langs
  end

  # "2:5" from the dialog as `%{season: 2, episode: 5}`; the default start when it is not one.
  defp study_episode(value, study) do
    with true <- is_binary(value),
         [s, e] <- String.split(value, ":"),
         {s, ""} <- Integer.parse(s),
         {e, ""} <- Integer.parse(e) do
      %{season: s, episode: e}
    else
      _ -> (study && study[:start]) || %{season: 1, episode: 1}
    end
  end

  # What a score means is laev's own list (`Laev.Ratings`); the colour it is drawn in is
  # `RokiWeb.ScoreColor`'s, which also hands the script its table, so the slider does not carry a
  # second copy of the scale.
  defp score_word(v) when is_number(v), do: Laev.Ratings.score_word(v)

  # Is the rating in hand the top score, which is gold rather than a colour on the ramp?
  defp gold?(%{value: value}), do: ScoreColor.gold?(value)

  defp fmt_rating(v) when is_number(v) do
    if v == trunc(v),
      do: Integer.to_string(trunc(v)),
      else: :erlang.float_to_binary(v * 1.0, decimals: 1)
  end

  defp watched_state?(%{type: "movie"}, lib), do: lib.watched?
  defp watched_state?(_title, lib), do: lib.all_watched?

  defp watched_label(%{type: "movie"}, %{watched?: true}), do: "Watched"
  defp watched_label(%{type: "movie"}, _lib), do: "Mark watched"
  defp watched_label(_title, %{all_watched?: true}), do: "Completed"
  defp watched_label(_title, _lib), do: "Mark as completed"

  defp meta(t) do
    [
      t.year,
      t.minutes && "#{t.minutes} min",
      seasons_text(t),
      episodes_text(t),
      t.genres != [] && Enum.join(Enum.take(t.genres, 3), ", ")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # Specials (season 0) are not counted: they are not the show's seasons or episodes.
  defp seasons_text(%{type: "tv", seasons: seasons}) do
    n = Enum.count(seasons, &(&1.number > 0))
    n > 0 && "#{n} #{if n == 1, do: "season", else: "seasons"}"
  end

  defp seasons_text(_), do: false

  # "Season 4 · 12 Mar 2026 (233 days ago)": when the latest season came (or comes), for a show
  # that has had more than one — with one, "First aired" already says it.
  defp newest_season(%{type: "tv", seasons: seasons}) do
    dated = Enum.filter(seasons, &(&1.number > 0 and is_binary(&1.air_date)))

    with true <- length(dated) > 1,
         %{number: n, air_date: date} <- Enum.max_by(dated, & &1.number),
         when_ when is_binary(when_) <- release_date(date) do
      "Season #{n} · #{when_}"
    else
      _ -> nil
    end
  end

  defp newest_season(_), do: nil

  defp episodes_text(%{type: "tv", seasons: seasons}) do
    n = seasons |> Enum.filter(&(&1.number > 0)) |> Enum.map(&(&1.episodes || 0)) |> Enum.sum()
    n > 0 && "#{n} #{if n == 1, do: "episode", else: "episodes"}"
  end

  defp episodes_text(_), do: false

  # "Start" for a film not begun, "Continue 59:39" once there is a position.
  defp play_label(secs) when is_integer(secs), do: "Continue #{clock(secs)}"
  defp play_label(_), do: "Start"

  defp clock(secs) do
    h = div(secs, 3600)
    m = div(rem(secs, 3600), 60)
    s = rem(secs, 60)
    pad = &(&1 |> Integer.to_string() |> String.pad_leading(2, "0"))
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{pad.(m)}:#{pad.(s)}"
  end

  attr :title, :map, required: true
  attr :resume, :any, default: nil
  attr :resume_secs, :any, default: nil

  attr :play, :map,
    default: %{season: 1, episode: 1, continue?: false, verb: "Start", label: "S1.E1"}

  attr :busy?, :boolean, default: false
  attr :split?, :boolean, default: false
  attr :cached?, :boolean, default: false
  attr :class, :string, default: nil

  # The big button. A film: one button, Start / Continue mm:ss. A series: two halves — the left
  # picks a season and episode, the right goes straight to the sources of S1.E1 (or wherever you
  # were) and starts the best one.
  defp play_button(%{title: %{type: "movie"}, split?: true} = assigns) do
    ~H"""
    <div class={["flex gap-2", @class]}>
      <.link
        navigate={~p"/sources/movie/#{@title.id}"}
        class="btn btn-primary btn-lg h-full min-h-0 flex-[2] gap-2 px-3 text-[length:inherit] shadow-md"
      >
        <.icon name="hero-queue-list" class="h-6 w-6" /> Sources
      </.link>
      <button
        phx-click="play"
        class="btn btn-primary btn-lg h-full min-h-0 flex-[3] gap-2 px-3 text-[length:inherit] shadow-md"
        disabled={@busy?}
      >
        <.icon name={if @cached?, do: "hero-bolt-solid", else: "hero-play-solid"} class="h-6 w-6" />
        {play_label(@resume_secs)}
      </button>
    </div>
    """
  end

  defp play_button(%{title: %{type: "movie"}} = assigns) do
    ~H"""
    <button
      phx-click="play"
      class={["btn btn-primary btn-lg gap-2 px-4 shadow-md sm:px-10", @class]}
      disabled={@busy?}
    >
      <.icon name={if @cached?, do: "hero-bolt-solid", else: "hero-play-solid"} class="h-6 w-6" />
      {play_label(@resume_secs)}
    </button>
    """
  end

  defp play_button(assigns) do
    ~H"""
    <div class={["flex gap-2", @class]}>
      <.link
        navigate={~p"/title/tv/#{@title.id}/episodes"}
        class="btn btn-primary btn-lg h-full min-h-0 flex-[2] gap-2 px-3 shadow-md text-[length:inherit]"
      >
        <.icon name="hero-queue-list" class="h-6 w-6" /> Episodes
      </.link>
      <.link
        navigate={~p"/sources/tv/#{@title.id}/#{@play.season}/#{@play.episode}?#{[auto: 1]}"}
        class={[
          "btn btn-primary btn-lg h-full min-h-0 flex-[3] gap-2 px-3 shadow-md text-[length:inherit]",
          @busy? && "btn-disabled"
        ]}
      >
        <.icon name={if @cached?, do: "hero-bolt-solid", else: "hero-play-solid"} class="h-6 w-6" />
        {@play.verb} {@play.label}
      </.link>
    </div>
    """
  end

  attr :uuid, :any, default: nil
  attr :linked?, :boolean, default: false

  defp access_notice(assigns) do
    ~H"""
    <div :if={@uuid == nil} class="alert text-sm">
      <span>Log in, and connect your debrid account through laev, to watch here.</span>
      <a href="/phoenix_kit/users/log-in" class="btn btn-sm">Log in</a>
    </div>
    <div :if={@uuid != nil and not @linked?} class="alert text-sm">
      <span>Connect laev in your corner to watch here — your Real-Debrid or TorBox account does the streaming.</span>
      <.link navigate={~p"/"} class="btn btn-sm">Connect laev</.link>
    </div>
    """
  end

  attr :title, :map, required: true
  attr :season, :any, default: nil
  attr :episodes, :any, default: nil
  attr :watched, :any, required: true
  attr :sections, :list, default: []
  attr :section, :map, default: nil
  attr :season_counts, :map, default: %{}
  attr :cached, :any, required: true
  attr :title_id, :integer, required: true
  attr :can_play?, :boolean, default: false
  attr :rating, :map, default: %{state: :loading, value: nil, provider: :tmdb}

  @doc false
  def episodes(assigns) do
    ~H"""
    <section class="space-y-4">
      <%!-- The season: which one, and the whole of it watched — the dropdown, and the same
            square watched button the episode rows carry. --%>
      <div class="flex gap-2">
        <%!-- The season: the site's own list rather than the browser's, so it looks and behaves the same
              on every system, can show where each season stands, and takes any styling. --%>
        <div :if={@sections != []} id="season-picker" class="relative min-w-0 flex-1">
          <button
            type="button"
            phx-click={JS.toggle(to: "#season-picker-panel", display: "block")}
            aria-haspopup="listbox"
            aria-label="Season"
            class="flex h-12 w-full items-center justify-between gap-3 rounded-full border border-base-300 bg-base-100/80 px-5 text-left text-base font-semibold transition hover:border-primary/50 sm:text-lg"
          >
            <span class="truncate">{@section && @section.label}</span>
            <.icon name="hero-chevron-down-micro" class="h-5 w-5 shrink-0 text-base-content/60" />
          </button>
          <div
            id="season-picker-panel"
            role="listbox"
            class="absolute left-0 right-0 top-full z-40 mt-2 hidden max-h-[22rem] overflow-y-auto rounded-2xl border border-base-300 bg-base-100 p-1.5 shadow-2xl"
            phx-click-away={JS.hide(to: "#season-picker-panel")}
            phx-window-keydown={JS.hide(to: "#season-picker-panel")}
            phx-key="escape"
          >
            <.link
              :for={sec <- @sections}
              patch={~p"/title/tv/#{@title_id}/episodes?#{[s: sec.key]}"}
              phx-click={JS.hide(to: "#season-picker-panel")}
              role="option"
              aria-selected={to_string(@section != nil and sec.key == @section.key)}
              class={[
                "flex items-center gap-3 rounded-xl px-4 py-3 text-base transition hover:bg-base-200",
                @section && sec.key == @section.key && "bg-base-200 font-semibold text-primary"
              ]}
            >
              <% done? = season_done?(sec, @section, @episodes, @watched, @season_counts) %>
              <span class={["min-w-0 flex-1 truncate", done? && "text-base-content/45"]}>
                {sec.label}
              </span>
              <span
                :if={!done? and is_integer(sec.total) and sec.total > 0}
                class="shrink-0 text-xs tabular-nums text-base-content/50"
              >
                {if @section && sec.key == @section.key,
                  do: Enum.count(@episodes || [], &MapSet.member?(@watched, &1.number)),
                  else: Map.get(@season_counts, sec.key, 0)}/{sec.total}
              </span>
              <.icon :if={done?} name="hero-eye-solid" class="h-5 w-5 shrink-0 text-success" />
            </.link>
          </div>
        </div>
        <%!-- MyAnimeList rates by season: the season picked is the one rated. --%>
        <button
          :if={@can_play? and @rating.state == :ok and @rating.provider == :mal}
          type="button"
          phx-click={JS.show(to: "#rate-sheet", display: "flex")}
          class="btn h-12 shrink-0 gap-1.5 rounded-full px-5"
          title="Rate this season on MyAnimeList"
          aria-label="Rate this season"
        >
          <.icon name="hero-star" class="h-6 w-6" />
          <span :if={@rating.value} class="font-semibold text-info">{fmt_rating(@rating.value)}</span>
          <span :if={!@rating.value} class="hidden sm:inline">Rate</span>
        </button>
        <%!-- The whole season, marked or cleared: the same square button the episode rows carry.
              It says where the season stands, in three states, because "everything that is out is
              watched" is not "the season is watched" while episodes are still to come: solid green
              only when there is nothing left to air, outlined when you are up to date and more is
              coming, plain when something that is out is unwatched. Clicking does the same in all
              three — it has to be able to unmark. --%>
        <% state = season_state(@episodes, @watched) %>
        <% to_come = Enum.count(@episodes || [], &(not &1.aired?)) %>
        <button
          :if={@can_play? and is_list(@episodes) and @episodes != []}
          phx-click="toggle_season"
          data-season={state}
          class={[
            "btn btn-square h-12 w-12 shrink-0 rounded-full",
            state == :complete && "btn-success",
            state == :up_to_date && "btn-outline btn-success"
          ]}
          title={season_title(state, to_come)}
          aria-label={season_aria(state, to_come)}
        >
          <.icon
            name={if state == :open, do: "hero-eye", else: "hero-eye-solid"}
            class="h-8 w-8"
          />
        </button>
      </div>

      <div :if={@episodes == nil} class="space-y-2" aria-busy="true">
        <div :for={_ <- 1..4} class="skeleton h-20 w-full rounded-box"></div>
      </div>
      <p :if={@episodes == []} class="text-base-content/60">No episodes listed for this season.</p>

      <ul :if={is_list(@episodes)} class="space-y-2">
        <li
          :for={e <- @episodes}
          class={[
            "relative flex items-center gap-4 rounded-2xl border border-base-300 bg-base-100/70 p-3 transition hover:border-primary/40",
            MapSet.member?(@watched, e.number) && "bg-base-200/60"
          ]}
        >
          <%!-- The whole row is one link to this episode's sources (a stretched link under the two
                buttons), so there is nowhere on it that does nothing. --%>
          <div class={[
            "flex min-w-0 flex-1 gap-3",
            MapSet.member?(@watched, e.number) && "opacity-45 grayscale"
          ]}>
            <div class="hidden aspect-video w-44 shrink-0 overflow-hidden rounded-xl bg-base-300 sm:block">
              <img
                :if={e.still}
                src={Roki.Images.local(e.still)}
                alt=""
                loading="lazy"
                class="h-full w-full object-cover"
              />
            </div>
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <.link
                  :if={@can_play? and e.aired?}
                  navigate={~p"/sources/tv/#{@title_id}/#{@season}/#{e.number}"}
                  class="font-medium after:absolute after:inset-0"
                >
                  {e.local}. {e.name}
                </.link>
                <span :if={not (@can_play? and e.aired?)} class="font-medium">{e.local}. {e.name}</span>
                <span
                  :if={MapSet.member?(@cached, {"tv", @title_id, @season, e.number})}
                  class="badge badge-sm badge-success badge-outline"
                >
                  ⚡ cached
                </span>
              </div>
              <div class="text-xs text-base-content/60">
                {[e.air_date, e.minutes && "#{e.minutes} min"]
                |> Enum.filter(& &1)
                |> Enum.join(" · ")}
                <span :if={not e.aired?}> · not out yet</span>
              </div>
              <p :if={e.overview} class="mt-1 line-clamp-2 text-sm text-base-content/70">
                {e.overview}
              </p>
            </div>
          </div>
          <div :if={@can_play? and e.aired?} class="relative z-10 flex shrink-0 items-center gap-2">
            <button
              phx-click="toggle_episode"
              phx-value-season={@season}
              phx-value-episode={e.number}
              class={[
                "btn btn-square h-12 w-12 rounded-full",
                MapSet.member?(@watched, e.number) && "btn-success"
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
                    do: "hero-eye-solid",
                    else: "hero-eye"
                }
                class="h-8 w-8"
              />
            </button>
            <.link
              navigate={~p"/sources/tv/#{@title_id}/#{@season}/#{e.number}?#{[auto: 1]}"}
              class="btn btn-primary h-12 w-12 rounded-full px-0 text-base sm:w-auto sm:px-6"
              aria-label="Play"
            >
              <.icon name="hero-play-solid" class="h-7 w-7" />
              <span class="hidden sm:inline">Play</span>
            </.link>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  # A season is done when every episode of it is marked. The open season is judged from the list
  # on screen (so it follows a tap at once); the others from laev's counts, no extra lookups.
  defp season_done?(%{key: key}, %{key: key}, eps, watched, _counts) when is_list(eps) do
    eps != [] and Enum.all?(eps, &(&1.aired? and MapSet.member?(watched, &1.number)))
  end

  defp season_done?(%{key: key, total: total}, _open, _eps, _watched, counts),
    do: is_integer(total) and total > 0 and Map.get(counts, key, 0) >= total

  @doc """
  Where a season stands: `:complete` when every episode of it is out and watched, `:up_to_date`
  when everything that is out is watched but more is still to air, and `:open` when something that
  is out has not been watched.

  The button beside the season picker drew a season as watched as soon as the episodes that had
  aired were: so a show part-way through its run, with six of eight out and six ticked, showed its
  season as completed, two episodes early.
  """
  def season_state(episodes, watched) when is_list(episodes) do
    out = for e <- episodes, e.aired?, do: e.number

    cond do
      out == [] -> :open
      not Enum.all?(out, &MapSet.member?(watched, &1)) -> :open
      Enum.all?(episodes, & &1.aired?) -> :complete
      true -> :up_to_date
    end
  end

  def season_state(_episodes, _watched), do: :open

  @doc false
  def season_title(:complete, _to_come), do: "Season watched — click to unmark"

  def season_title(:up_to_date, to_come),
    do: "Up to date: everything that is out is watched, #{to_come} still to air — click to unmark"

  def season_title(:open, 0), do: "Mark the whole season watched"
  def season_title(:open, _to_come), do: "Mark the episodes that are out as watched"

  @doc false
  def season_aria(:complete, _to_come), do: "Unmark season watched"
  def season_aria(:up_to_date, _to_come), do: "Unmark the episodes watched so far"
  def season_aria(:open, 0), do: "Mark season watched"
  def season_aria(:open, _to_come), do: "Mark the episodes that are out as watched"

  # ── the phone layout ───────────────────────────────────────────────

  # The less used actions behind the dots, top right of the title: on hold (anime has none:
  # MyAnimeList keeps that) and the title's page on TMDB and, for anime, on MyAnimeList.
  attr :id, :string, required: true
  attr :title, :map, required: true
  attr :linked?, :boolean, default: false
  attr :lib, :map, required: true
  attr :mal, :any, default: nil
  attr :link?, :boolean, default: false
  attr :link_state, :any, default: :none
  attr :trailer, :any, default: nil
  attr :button_class, :string, default: ""

  defp more_menu(assigns) do
    assigns =
      assigns
      |> assign(:hold?, assigns.linked? and not assigns.title.anime?)
      |> assign(:links, external_links(assigns.title, assigns.mal))

    ~H"""
    <%!-- `relative`: the menu opens under this button, not at the edge of whatever box holds it. --%>
    <div class="relative shrink-0">
      <button
        type="button"
        phx-click={JS.toggle(to: "##{@id}", display: "block")}
        class={["btn btn-ghost btn-circle btn-sm relative", @button_class]}
        aria-label="More actions"
        aria-controls={@id}
      >
        <.icon name="hero-ellipsis-horizontal" class="h-6 w-6" />
        <span
          :if={@hold? and @lib.held?}
          class="absolute right-1 top-1 h-2.5 w-2.5 rounded-full bg-warning"
          title="On hold"
        ></span>
      </button>
      <div
        id={@id}
        class="absolute right-0 top-full z-40 mt-1 hidden w-56 rounded-box border border-base-300 bg-base-100 p-1 text-base-content shadow-xl"
        phx-click-away={JS.hide(to: "##{@id}")}
        phx-window-keydown={JS.hide(to: "##{@id}")}
        phx-key="escape"
      >
        <button
          :if={@trailer}
          type="button"
          phx-click={open_trailer() |> JS.hide(to: "##{@id}")}
          class="flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left text-sm font-medium hover:bg-base-200"
        >
          <.icon name="hero-play-circle" class="h-5 w-5" /> Watch trailer
        </button>
        <button
          :if={@link?}
          type="button"
          phx-click={JS.show(to: "#link-sheet", display: "flex") |> JS.hide(to: "##{@id}")}
          class="flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left text-sm font-medium hover:bg-base-200"
        >
          <.icon
            name={if @link_state in [:none, :pending], do: "hero-link", else: "hero-link-solid"}
            class={["h-5 w-5", @link_state not in [:none, :pending] && "text-primary"]}
          />
          <span class="truncate">{link_label(@link_state)}</span>
        </button>
        <button
          :if={@hold?}
          type="button"
          phx-click={JS.push("toggle_hold") |> JS.hide(to: "##{@id}")}
          class="flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left text-sm font-medium hover:bg-base-200"
        >
          <.icon
            name={if @lib.held?, do: "hero-pause-circle-solid", else: "hero-pause-circle"}
            class={["h-5 w-5", @lib.held? && "text-warning"]}
          />
          {if @lib.held?, do: "On hold — take it off", else: "Put on hold"}
        </button>
        <button
          :if={@linked? and @lib[:progress?]}
          type="button"
          phx-click={JS.push("forget_progress") |> JS.hide(to: "##{@id}")}
          data-confirm={forget_confirm(@title)}
          class="flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left text-sm font-medium text-error hover:bg-error/10"
        >
          <.icon name="hero-arrow-uturn-left" class="h-5 w-5" /> Remove watch progress
        </button>
        <a
          :for={{label, url} <- @links}
          href={url}
          target="_blank"
          rel="noopener noreferrer"
          class="flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left text-sm font-medium hover:bg-base-200"
        >
          <.icon name="hero-arrow-top-right-on-square" class="h-5 w-5" />
          {label}
        </a>
      </div>
    </div>
    """
  end

  defp forget_confirm(%{type: "tv", title: title}),
    do:
      "Remove all watch progress for #{title}? The episodes you marked as watched are cleared too."

  defp forget_confirm(%{title: title}), do: "Remove the watch progress for #{title}?"

  # Where else the title lives: MyAnimeList first for anime (its first season's entry, or the
  # film itself — the cross-id list, no request), then TMDB and, when TMDB knows it, IMDb.
  defp external_links(t, entry) do
    kind = if t.type == "movie", do: "movie", else: "tv"

    mal =
      if t.anime? do
        ids = Laev.AnimeMap.mal_ids(kind, t.id)

        first =
          cond do
            is_integer(entry) -> entry
            entry == :none -> nil
            kind == "movie" -> List.first(ids)
            true -> Laev.Anime.Parts.first_entry(t.id)
          end

        cond do
          is_integer(first) ->
            [{"Open on MyAnimeList", "https://myanimelist.net/anime/#{first}"}]

          # The season is not in the cross-id list yet: search for it by name.
          entry == :none ->
            q = URI.encode_www_form(t.title || "")
            [{"Search on MyAnimeList", "https://myanimelist.net/anime.php?q=#{q}"}]

          true ->
            []
        end
      else
        []
      end

    imdb =
      case t.imdb_id do
        "tt" <> _ = id -> [{"Open on IMDb", "https://www.imdb.com/title/#{id}/"}]
        _ -> []
      end

    mal ++ [{"Open on TMDB", "https://www.themoviedb.org/#{kind}/#{t.id}"}] ++ imdb
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
  attr :study, :map, required: true
  attr :eps, :any, default: nil

  # Study mode, from a desktop: which languages to watch this title in, without touching the
  # account's settings. What was chosen last time is already filled in.
  defp study_sheet(assigns) do
    assigns =
      assign(assigns,
        audio: Roki.Languages.choices(assigns.study.lang),
        subs: Roki.Languages.choices(assigns.study.subs),
        tr: Roki.Languages.choices(assigns.study.tr)
      )

    ~H"""
    <div
      id="study-sheet"
      class="fixed inset-0 z-[70] !m-0 hidden items-center justify-center bg-black/50"
      phx-window-keydown={JS.hide(to: "#study-sheet")}
      phx-key="escape"
    >
      <form
        id="study-form"
        phx-submit="study_go"
        phx-click-away={JS.hide(to: "#study-sheet")}
        class="w-full max-w-md space-y-4 rounded-2xl bg-base-100 p-6 shadow-2xl"
      >
        <div class="flex items-start gap-3">
          <div class="min-w-0 flex-1">
            <h2 class="text-lg font-bold leading-tight">Study {@title.title}</h2>
            <p class="text-sm text-base-content/60">
              Watch this one in the languages below. Your settings stay as they are; the choice is
              remembered for this title.
            </p>
          </div>
          <button
            type="button"
            phx-click={JS.hide(to: "#study-sheet")}
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>

        <label class="block space-y-1">
          <span class="text-sm font-medium">Audio language</span>
          <select name="lang" class="select select-bordered w-full">
            <.language_options choices={@audio} current={@study.lang} />
          </select>
        </label>

        <label class="block space-y-1">
          <span class="text-sm font-medium">Subtitle language</span>
          <select name="subs" class="select select-bordered w-full">
            <option value="off" selected={@study.subs == "off"}>Off — no subtitles</option>
            <.language_options choices={@subs} current={@study.subs} />
          </select>
        </label>

        <label class="block space-y-1">
          <span class="text-sm font-medium">Translation subtitles</span>
          <select name="tr" class="select select-bordered w-full">
            <option value="off" selected={@study.tr == "off"}>Off — only the subtitles above</option>
            <.language_options choices={@tr} current={@study.tr} />
          </select>
          <span class="block text-xs text-base-content/60">
            Shown under the subtitles you study. Starts as your account's language.
          </span>
        </label>

        <label :if={@title.type == "tv" and @study[:start]} class="block space-y-1">
          <span class="text-sm font-medium">Episode</span>
          <select name="ep" class="select select-bordered w-full">
            <%!-- Until the list is read, the one it starts on is the only choice. --%>
            <option
              :if={@eps == nil}
              value={"#{@study.start.season}:#{@study.start.episode}"}
              selected
            >
              {@study.start.label} — next to watch
            </option>
            <optgroup :for={{label, eps} <- @eps || []} label={label}>
              <option
                :for={e <- eps}
                value={"#{e.season}:#{e.number}"}
                disabled={!e.aired?}
                selected={e.season == @study.start.season and e.number == @study.start.episode}
              >
                {if e.watched?, do: "✓ ", else: ""}{e.label}{if e.name, do: " · " <> e.name, else: ""}{if e.season ==
                                                                                                            @study.start.season and
                                                                                                            e.number ==
                                                                                                              @study.start.episode,
                                                                                                          do:
                                                                                                            "  (next)",
                                                                                                          else:
                                                                                                            ""}
              </option>
            </optgroup>
          </select>
        </label>

        <button type="submit" class="btn btn-primary w-full">
          <.icon name="hero-magnifying-glass" class="h-5 w-5" /> Search and play
        </button>
      </form>
    </div>
    """
  end

  attr :choices, :map, required: true
  attr :current, :string, required: true

  defp language_options(assigns) do
    ~H"""
    <option :for={{code, label} <- @choices.extra} value={code} selected>{label}</option>
    <optgroup label="Common">
      <option :for={{code, label} <- @choices.common} value={code} selected={@current == code}>
        {label}
      </option>
    </optgroup>
    <optgroup label="All languages">
      <option :for={{code, label} <- @choices.rest} value={code} selected={@current == code}>
        {label}
      </option>
    </optgroup>
    """
  end

  attr :title, :map, required: true
  attr :reviews, :any, default: nil

  # What the rating sites made of it, and how the critics took it. Opened from the score in the
  # hero; what it shows is fetched the first time (`Roki.Reviews`).
  defp reviews_sheet(assigns) do
    ~H"""
    <div
      id="reviews-sheet"
      class="fixed inset-0 z-[70] !m-0 hidden items-end bg-black/50 sm:items-center sm:justify-center"
      phx-window-keydown={JS.hide(to: "#reviews-sheet")}
      phx-key="escape"
    >
      <div
        class="flex max-h-[88svh] w-full flex-col overflow-hidden rounded-t-2xl bg-base-100 shadow-2xl sm:max-w-2xl sm:rounded-2xl"
        phx-click-away={JS.hide(to: "#reviews-sheet")}
      >
        <div class="flex items-start gap-3 border-b border-base-300 p-5">
          <div class="min-w-0 flex-1">
            <h2 class="text-lg font-bold leading-tight">Reviews</h2>
            <p class="truncate text-sm text-base-content/60">{@title.title}</p>
          </div>
          <button
            type="button"
            phx-click={JS.hide(to: "#reviews-sheet")}
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>

        <div class="space-y-6 overflow-y-auto p-5">
          <div :if={@reviews in [nil, :loading]} class="space-y-4" aria-busy="true">
            <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <div :for={_ <- 1..8} class="skeleton h-20 rounded-box"></div>
            </div>
            <div class="skeleton h-4 w-full rounded"></div>
            <div class="skeleton h-4 w-5/6 rounded"></div>
          </div>

          <p :if={@reviews == :error} class="text-sm text-base-content/70">
            Couldn't reach the review sites just now. Close this and try again in a minute.
          </p>

          <%= if is_map(@reviews) do %>
            <section :if={@reviews.scores != []} class="space-y-2">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Scores
              </h3>
              <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
                <.score_tile :for={sc <- @reviews.scores} sc={sc} />
              </div>
              <p class="text-xs text-base-content/50">
                Each score is set against what a typical title gets on that service (the tick on the
                bar), since a 6.6 on IMDb and a 60% on Rotten Tomatoes are both ordinary. Tap a score to
                open the title there.
              </p>
            </section>

            <section :if={@reviews.critics} class="space-y-2">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                What critics said
              </h3>
              <p
                :for={para <- @reviews.critics.paragraphs}
                class="text-sm leading-relaxed text-base-content/85"
              >
                {para}
              </p>
              <a
                href={@reviews.critics.url}
                target="_blank"
                rel="noopener"
                class="link text-sm font-medium"
              >
                Read more on Wikipedia
              </a>
            </section>

            <p
              :if={@reviews.scores == [] and is_nil(@reviews.critics)}
              class="text-sm text-base-content/70"
            >
              Nothing to show for this one yet: the rating sites have no scores for it and there is no
              write-up of how it was received.
            </p>

            <p class="text-xs text-base-content/45">
              <span :if={@reviews.scores != []}>Scores from MDBList</span>
              <span :if={@reviews.scores != [] and @reviews.critics}> · </span>
              <span :if={@reviews.critics}>Summary from Wikipedia (CC BY-SA)</span>
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :sc, :map, required: true

  # One service's score; a link to the title on that service when we have the address. Put against
  # what is typical on that service (`Roki.Reviews.compare/3`): the number takes the colour of how
  # it fares — green well above, amber about typical, red well below — and a bar shows the score
  # with a tick where a typical title sits.
  defp score_tile(assigns) do
    assigns = assign(assigns, :tone, score_tone(assigns.sc[:verdict]))

    ~H"""
    <.link_or_div url={@sc[:url]} border={@tone.border}>
      <div class={["text-2xl font-bold tabular-nums leading-tight", @tone.text]}>{@sc.text}</div>
      <div class="flex items-center gap-1 text-sm font-semibold leading-tight">
        {@sc.label}
        <.icon
          :if={@sc[:url]}
          name="hero-arrow-top-right-on-square-micro"
          class="h-3.5 w-3.5 text-base-content/40"
        />
      </div>
      <div class="text-xs text-base-content/60">
        {@sc.who}<span :if={@sc.votes}> · {thousands(@sc.votes)} ratings</span>
      </div>
      <div :if={@sc[:norm]} class="mt-2 space-y-1">
        <div
          class="relative h-1.5 rounded-full bg-base-300"
          role="img"
          aria-label={score_verdict(@sc)}
          title={"A typical title scores about #{@sc.typical} out of 100 on #{@sc.label}"}
        >
          <div class={["h-full rounded-full", @tone.bar]} style={"width: #{min(@sc.norm, 100)}%"}>
          </div>
          <span
            class="absolute -top-0.5 h-2.5 w-0.5 rounded bg-base-content/60"
            style={"left: #{@sc.typical}%"}
          ></span>
        </div>
        <div class={["text-[0.7rem] font-medium leading-tight", @tone.text]}>
          {score_verdict(@sc)}
        </div>
      </div>
    </.link_or_div>
    """
  end

  defp score_tone(:great),
    do: %{text: "text-success", bar: "bg-success", border: "border-success/40"}

  defp score_tone(:good),
    do: %{text: "text-success/80", bar: "bg-success/70", border: "border-success/25"}

  defp score_tone(:typical),
    do: %{text: "text-warning", bar: "bg-warning/80", border: "border-base-300"}

  defp score_tone(:below),
    do: %{text: "text-orange-500", bar: "bg-orange-400", border: "border-orange-400/30"}

  defp score_tone(:poor), do: %{text: "text-error", bar: "bg-error", border: "border-error/30"}
  defp score_tone(_), do: %{text: "", bar: "bg-base-content/30", border: "border-base-300"}

  defp score_verdict(%{verdict: verdict, delta: delta}) do
    sign = if delta > 0, do: "+#{delta}", else: "#{delta}"

    case verdict do
      :great -> "Far above typical · #{sign}"
      :good -> "Above typical · #{sign}"
      :typical -> "About typical"
      :below -> "Below typical · #{sign}"
      :poor -> "Far below typical · #{sign}"
    end
  end

  attr :url, :string, default: nil
  attr :border, :string, default: "border-base-300"
  slot :inner_block, required: true

  defp link_or_div(%{url: url} = assigns) when is_binary(url) do
    ~H"""
    <a
      href={@url}
      target="_blank"
      rel="noopener"
      class={[
        "block rounded-box border bg-base-200/50 p-3 transition hover:border-primary/60 hover:bg-base-200",
        @border
      ]}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  defp link_or_div(assigns) do
    ~H"""
    <div class={["rounded-box border bg-base-200/50 p-3", @border]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp open_trailer,
    do:
      JS.show(to: "#trailer-sheet", display: "flex")
      |> JS.dispatch("roki:trailer-open", to: "#trailer-sheet")

  defp close_trailer,
    do: JS.hide(to: "#trailer-sheet") |> JS.dispatch("roki:trailer-close", to: "#trailer-sheet")

  attr :key, :string, required: true
  attr :title, :map, required: true

  # The trailer, played here (a YouTube embed made when the sheet opens), with a way out to YouTube.
  @doc false
  def trailer_sheet(assigns) do
    ~H"""
    <div
      id="trailer-sheet"
      phx-hook="TrailerSheet"
      data-key={@key}
      class="fixed inset-0 z-[70] !m-0 hidden items-center justify-center bg-black/85 p-3 sm:p-8"
      phx-window-keydown={close_trailer()}
      phx-key="escape"
    >
      <div class="w-full max-w-5xl" phx-click-away={close_trailer()}>
        <div class="mb-2 flex items-center justify-between gap-3 text-white">
          <h2 class="min-w-0 truncate text-lg font-semibold">{@title.title} · Trailer</h2>
          <div class="flex shrink-0 items-center gap-1">
            <a
              href={"https://www.youtube.com/watch?v=#{@key}"}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-ghost btn-sm gap-1 text-white"
            >
              Open on YouTube <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" />
            </a>
            <button
              type="button"
              phx-click={close_trailer()}
              class="btn btn-ghost btn-sm btn-circle text-white"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="h-5 w-5" />
            </button>
          </div>
        </div>
        <div
          id="trailer-frame"
          data-trailer-frame
          phx-update="ignore"
          class="aspect-video w-full overflow-hidden rounded-xl bg-black"
        >
        </div>
      </div>
    </div>
    """
  end

  defp link_label(:none), do: "Link progress"
  defp link_label(:invited), do: "Link request"
  defp link_label(:pending), do: "Link pending"
  defp link_label({:linked, names}), do: "Linked with " <> Enum.join(names, ", ")

  defp link_title(:none), do: "Link this show's progress with friends"
  defp link_title(:invited), do: "A friend asked to link progress on this show"
  defp link_title(:pending), do: "Invitation sent: nothing is shared until they accept"
  defp link_title({:linked, _}), do: "Progress linked: open to pause, add someone or unlink"

  attr :uuid, :string, required: true
  attr :title, :map, required: true

  # The link panel (RokiWeb.LinkProgress) in a sheet, for the title's own page. The episodes page
  # has the same panel inline.
  defp link_sheet(assigns) do
    ~H"""
    <div
      id="link-sheet"
      class="fixed inset-0 z-[70] !m-0 hidden items-end bg-black/50 sm:items-center sm:justify-center"
      phx-window-keydown={JS.hide(to: "#link-sheet")}
      phx-key="escape"
    >
      <div
        class="max-h-[85svh] w-full overflow-y-auto rounded-t-2xl bg-base-100 p-4 pb-[max(1.5rem,env(safe-area-inset-bottom))] shadow-2xl sm:max-w-md sm:rounded-2xl"
        phx-click-away={JS.hide(to: "#link-sheet")}
      >
        <div class="mb-3 flex items-start gap-3">
          <h2 class="min-w-0 flex-1 text-lg font-bold leading-tight">
            Link progress · {@title.title}
          </h2>
          <button
            type="button"
            phx-click={JS.hide(to: "#link-sheet")}
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>
        <.live_component module={RokiWeb.LinkProgress} id="link-progress" uuid={@uuid} title={@title} />
      </div>
    </div>
    """
  end

  attr :title, :map, required: true
  attr :rating, :map, required: true
  attr :error, :string, default: nil
  attr :label, :string, default: nil

  # Where you rate: TMDB's score for reference, a half-step slider, save or take it back.
  @doc false
  def rate_sheet(assigns) do
    ~H"""
    <div
      id="rate-sheet"
      data-words={Jason.encode!(for {n, w} <- Laev.Ratings.score_words(), into: %{}, do: {n, w})}
      data-colors={Jason.encode!(RokiWeb.ScoreColor.table())}
      class="fixed inset-0 z-[70] !m-0 hidden items-end bg-black/50 sm:items-center sm:justify-center"
      phx-window-keydown={JS.hide(to: "#rate-sheet")}
      phx-key="escape"
    >
      <div
        class="w-full rounded-t-2xl bg-base-100 p-5 pb-[max(2rem,env(safe-area-inset-bottom))] shadow-2xl sm:max-w-sm sm:rounded-2xl sm:pb-5"
        phx-click-away={JS.hide(to: "#rate-sheet")}
      >
        <div class="flex items-start gap-3">
          <div class="min-w-0 flex-1">
            <h2 class="text-lg font-bold leading-tight">
              Rate {@title.title}<span :if={@label}> · {@label}</span>
            </h2>
            <p class="text-sm text-base-content/60">
              <span class="font-semibold text-warning">★ {avg_text(@title)}</span>
              on TMDB<span :if={@title.vote_count && @title.vote_count > 0}> · {thousands(
                @title.vote_count
              )} votes</span><span :if={@rating.provider == :mal}> · your score goes to MyAnimeList</span><span :if={
                @rating.provider == :roki
              }> · your score is kept on Roki</span>
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

        <p
          :if={@rating.state == :no_account and @rating.provider == :mal}
          class="mt-4 text-sm text-base-content/70"
        >
          Anime ratings go to MyAnimeList. Connect your account on the <.link
            navigate={~p"/account/services"}
            class="link"
          >services page</.link>, then rate here.
        </p>

        <form
          :if={@rating.state == :ok}
          id="rate-form"
          phx-submit={JS.push("rate") |> JS.hide(to: "#rate-sheet")}
          class="mt-4 space-y-4"
        >
          <div class="text-center">
            <p
              id="rate-word"
              class={["text-sm font-semibold uppercase tracking-wider", gold?(@rating) && "rate-gold"]}
              style={!gold?(@rating) && "color: #{ScoreColor.color(@rating.value || 7)}"}
            >
              {score_word(@rating.value || 7)}
            </p>
            <span
              id="rate-out"
              class={["text-5xl font-bold", gold?(@rating) && "rate-gold"]}
              style={!gold?(@rating) && "color: #{ScoreColor.color(@rating.value || 7)}"}
            >{fmt_rating(@rating.value || 7)}</span>
            <span class="text-lg text-base-content/50"> / 10</span>
          </div>
          <input
            type="range"
            name="value"
            min={if @rating.provider == :mal, do: "1", else: "0.5"}
            max="10"
            step={if @rating.provider == :mal, do: "1", else: "0.5"}
            value={@rating.value || 7}
            oninput="rokiScore(this)"
            data-gold={gold?(@rating) && ""}
            style={"--c: #{ScoreColor.color(@rating.value || 7)}; --p: #{ScoreColor.fraction(@rating.value || 7, if(@rating.provider == :mal, do: 1, else: 0.5))}"}
            class="rate-range w-full"
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
          <p :if={@rating.provider == :roki} class="text-center text-xs text-base-content/60">
            Kept on Roki.
            <a
              href={~p"/tmdb/link?#{[return: "/title/#{@title.type}/#{@title.id}"]}"}
              class="link"
            >Link a TMDB account</a>
            to send your ratings there too.
          </p>
          <p :if={@rating.value} class="text-center text-xs text-base-content/60">
            Your rating:
            <span class={["font-semibold", (gold?(@rating) && "rate-gold") || "text-info"]}>
              {fmt_rating(@rating.value)}
            </span>
          </p>
        </form>

        <p :if={@rating.state == :loading} class="mt-4 text-sm text-base-content/60">Loading…</p>
        <p :if={@error} class="mt-3 text-sm text-error">{@error}</p>
      </div>
    </div>
    """
  end
end
