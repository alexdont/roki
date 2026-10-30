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
      _ -> {:ok, push_navigate(socket, to: ~p"/home")}
    end
  end

  def mount(%{"id" => id}, _session, socket) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, init(socket, "tv", n)}
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
        cached: MapSet.new(),
        lib: %{saved?: false, held?: false, watched?: false, all_watched?: false},
        lib_busy: false,
        solo?: false,
        rating: %{state: :loading, value: nil, provider: :tmdb},
        rate_mal: nil,
        rating_error: nil,
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
        |> follow_section(wanted)
        |> load_episodes(wanted)

      true ->
        socket
    end
  end

  defp select(socket), do: socket

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
     |> select()}
  end

  def handle_async(:similar, {:ok, {:ok, cards, seen}}, socket),
    do: {:noreply, assign(socket, similar: cards, similar_seen: seen)}

  def handle_async(:similar, _other, socket), do: {:noreply, socket}

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

  def handle_info({:link_marked, id}, %{assigns: %{id: id}} = socket),
    do: {:noreply, reload_marks(socket)}

  def handle_info(_other, socket), do: {:noreply, socket}

  defp reload_marks(%{assigns: %{live_action: :episodes, section: %{} = sec}} = socket),
    do: load_episodes(socket, sec)

  defp reload_marks(socket), do: socket

  # ── view ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    # A title's page on a phone is exactly one screen: nothing sits below it (Play opens the next
    # page), so it does not scroll.
    assigns =
      assign(
        assigns,
        :locked?,
        assigns.live_action == :show and assigns.title != nil and assigns.linked? and
          assigns.title_error == nil
      )

    ~H"""
    <Layouts.app
      socket={@socket}
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

      <div :if={@title && @live_action == :show} class="space-y-8">
        <.phone_hero
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
          rating={@rating}
          locked?={@locked?}
          mal={@rate_mal}
        />

        <.rate_sheet
          :if={@linked?}
          title={@title}
          rating={@rating}
          error={@rating_error}
          label={rate_label(@sections, @rate_mal)}
        />

        <.hero
          mal={@rate_mal}
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
        >
          <.title_comments
            :if={@title.type in ["movie", "tv"]}
            id="title-comments"
            title={@title}
            user={assigns[:phoenix_kit_current_user]}
          />
        </.hero>

        <.study_sheet :if={@linked? and @study} title={@title} study={@study} eps={@study_eps} />

        <.access_notice uuid={@uuid} linked?={@linked?} />

        <%!-- A phone has one column, so its comments come after the details. A wide screen has them
              in the hero, under the Play controls. --%>
        <div :if={@title.type in ["movie", "tv"]} class="sm:hidden">
          <.title_comments
            id="title-comments-phone"
            title={@title}
            user={assigns[:phoenix_kit_current_user]}
          />
        </div>

        <%!-- A phone's title page is one screen that does not scroll, so this is for wider ones. --%>
        <section :if={@similar != []} class="hidden space-y-3 sm:block" aria-label="More like this">
          <h2 class="text-lg font-semibold">More like this</h2>
          <ul class="grid grid-cols-3 gap-4 md:grid-cols-4 lg:grid-cols-6">
            <li :for={i <- Enum.take(@similar, 12)}>
              <RokiWeb.PosterComponents.poster
                item={i}
                seen={MapSet.member?(@similar_seen, {i.type, i.id})}
                cached_titles={@cached_titles}
              />
            </li>
          </ul>
        </section>

        <%!-- On a phone the Play bar is fixed to the screen's bottom; leave room under the page. --%>
        <div :if={!@locked?} class="h-36 sm:hidden" aria-hidden="true"></div>
      </div>

      <div :if={@title && @live_action == :episodes} class="space-y-6">
        <.episodes_header
          title={@title}
          play={@play}
          resume={@resume}
          linked?={@linked?}
          lib={@lib}
          mal={@rate_mal}
        />
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
    <div class="relative isolate overflow-visible rounded-3xl border border-base-300/70 bg-base-200">
      <div class="absolute inset-0 -z-10 overflow-hidden rounded-3xl">
        <img
          :if={@title.backdrop}
          src={Roki.Images.local(@title.backdrop)}
          alt=""
          class="h-full w-full object-cover opacity-60"
        />
        <div class="absolute inset-0 bg-gradient-to-r from-base-100 via-base-100/90 to-base-100/55">
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-4 p-4 sm:flex-nowrap sm:gap-6 sm:p-6">
        <.link navigate={~p"/title/tv/#{@title.id}"} class="shrink-0" aria-label="Back to the title">
          <img
            :if={@title.poster}
            src={Roki.Images.local(@title.poster)}
            alt={@title.title}
            class="aspect-[2/3] w-16 rounded-xl bg-base-300 object-cover shadow-xl ring-1 ring-black/10 sm:w-24"
          />
        </.link>
        <div class="min-w-0 flex-1 space-y-1.5 basis-40">
          <.link
            navigate={~p"/title/tv/#{@title.id}"}
            class="inline-flex items-center gap-1 whitespace-nowrap text-sm text-base-content/60 hover:text-primary"
          >
            <.icon name="hero-chevron-left-micro" class="h-4 w-4" /> The title
          </.link>
          <h1 class="text-2xl font-bold leading-tight tracking-tight sm:text-4xl">{@title.title}</h1>
          <p class="hidden text-sm text-base-content/60 sm:block">{meta(@title)}</p>
          <p class="text-xs text-base-content/60 sm:hidden">
            {[@title.year, seasons_text(@title)] |> Enum.filter(& &1) |> Enum.join(" · ")}
          </p>
        </div>
        <div class="flex shrink-0 items-center gap-2 max-sm:w-full">
          <.link
            :if={@play.continue?}
            navigate={~p"/sources/tv/#{@title.id}/#{@play.season}/#{@play.episode}?#{[auto: 1]}"}
            class="btn btn-primary h-11 rounded-xl px-4 shadow-md max-sm:flex-1 sm:h-12 sm:px-6"
          >
            <.icon name="hero-play-solid" class="h-5 w-5" /> {@play.verb} {@play.label}
          </.link>
          <.more_menu id="more-menu-eps" title={@title} linked?={@linked?} lib={@lib} mal={@mal} />
        </div>
      </div>
    </div>
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
  attr :study, :map, default: nil

  slot :inner_block,
    doc:
      "more for the right-hand column, under the Play controls (the comments, on a wide screen)"

  defp hero(assigns) do
    ~H"""
    <section class="hidden space-y-6 sm:block">
      <%!-- The banner: the film's own backdrop, washed into the page colour so the words stay readable
            in the light and the dark theme alike; the poster stands on it. --%>
      <div class="relative isolate rounded-3xl border border-base-300/70 bg-base-200">
        <%!-- The backdrop is clipped to the banner's corners; the banner itself is not, so the
              "…" menu can open below its edge. --%>
        <div class="absolute inset-0 -z-10 overflow-hidden rounded-3xl">
          <img
            :if={@title.backdrop}
            src={Roki.Images.local(@title.backdrop)}
            alt=""
            class="h-full w-full object-cover opacity-60"
          />
          <div class="absolute inset-0 bg-gradient-to-r from-base-100 via-base-100/90 to-base-100/55">
          </div>
          <div class="absolute inset-x-0 bottom-0 h-24 bg-gradient-to-t from-base-100/70 to-transparent">
          </div>
        </div>

        <div class="flex gap-8 p-6 lg:p-8">
          <div class="w-48 shrink-0 lg:w-60">
            <img
              :if={@title.poster}
              src={Roki.Images.local(@title.poster)}
              alt={@title.title}
              class="aspect-[2/3] w-full rounded-2xl bg-base-300 object-cover shadow-2xl ring-1 ring-black/10"
            />
            <div :if={!@title.poster} class="aspect-[2/3] w-full rounded-2xl bg-base-300"></div>
          </div>

          <div class="flex min-w-0 flex-1 flex-col gap-4">
            <div class="flex items-start gap-3">
              <div class="min-w-0 flex-1 space-y-2">
                <h1 class="text-3xl font-bold leading-tight tracking-tight lg:text-5xl">
                  {@title.title}
                </h1>
                <.facts_row title={@title} rating={@rating} linked?={@linked?} />
                <p :if={@title.tagline} class="italic text-base-content/60">{@title.tagline}</p>
              </div>
              <.more_menu id="more-menu-desk" title={@title} linked?={@linked?} lib={@lib} mal={@mal} />
            </div>

            <p :if={@title.overview} class="max-w-3xl leading-relaxed text-base-content/85">
              {@title.overview}
            </p>

            <div class="mt-auto space-y-4 pt-2">
              <div class="flex flex-wrap items-center gap-3">
                <.play_button
                  title={@title}
                  play={@play}
                  resume={@resume}
                  resume_secs={@resume_secs}
                  busy?={match?({:working, _}, @phase)}
                  class="h-12 min-w-[14rem] rounded-xl text-lg lg:h-14 lg:text-xl"
                />
                <button
                  :if={@linked? and @study}
                  type="button"
                  phx-click={JS.show(to: "#study-sheet", display: "flex") |> JS.push("study_open")}
                  class="btn btn-outline h-12 gap-2 rounded-xl lg:h-14"
                  title="Watch this in languages you choose, leaving your settings alone"
                >
                  <.icon name="hero-academic-cap" class="h-5 w-5" /> Study
                </button>
                <.link
                  :if={@linked? and @title.type == "movie"}
                  navigate={~p"/sources/movie/#{@title.id}"}
                  class="btn btn-ghost h-12 gap-2 rounded-xl lg:h-14"
                  title="Choose which release to play"
                >
                  <.icon name="hero-queue-list" class="h-5 w-5" /> Sources
                </.link>
                <span
                  :if={@cached?}
                  class="badge badge-success badge-outline gap-1"
                  title="Sources are cached: plays right away"
                >
                  ⚡ cached
                </span>
                <%!-- Where Play opens it, right beside it. --%>
                <Layouts.player_switch :if={@linked?} class="ml-auto" />
              </div>

              <%!-- Away from Play: a slip here should not save or hold a title. --%>
              <.action_pills
                :if={@linked?}
                title={@title}
                lib={@lib}
                busy={@lib_busy}
                rating={@rating}
              />
            </div>
          </div>
        </div>
      </div>

      <%!-- More for under the banner (the comments, on a wide screen). --%>
      <div>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :title, :map, required: true
  attr :rating, :map, required: true
  attr :linked?, :boolean, default: false

  # Year, length and the rest as quiet chips, the score beside them (yours in its own colour once
  # you have rated it; a click changes it).
  defp facts_row(assigns) do
    assigns =
      assign(
        assigns,
        :chips,
        Enum.filter(
          [
            assigns.title.year,
            assigns.title.minutes && "#{assigns.title.minutes} min",
            seasons_text(assigns.title),
            episodes_text(assigns.title)
          ],
          & &1
        )
      )

    ~H"""
    <div class="flex flex-wrap items-center gap-x-2 gap-y-2 text-sm">
      <span :for={c <- @chips} class="rounded-full bg-base-content/10 px-3 py-1 font-medium">{c}</span>
      <span
        :for={g <- Enum.take(@title.genres, 3)}
        class="rounded-full border border-base-content/20 px-3 py-1 text-base-content/70"
      >
        {g}
      </span>
    </div>
    """
  end

  attr :title, :map, required: true
  attr :lib, :map, required: true
  attr :busy, :boolean, default: false
  attr :rating, :map, required: true

  # The icon classes below are built from a name, which Tailwind cannot see, so they are spelled
  # out here: hero-bookmark hero-bookmark-solid hero-pause-circle hero-pause-circle-solid
  # hero-check-circle hero-check-circle-solid
  # What the terminal app has on a title: saved for later, watched (and back), and your rating —
  # as pills with their words, the same colours as the hover card on a poster. Hold is in the
  # "…" menu (it is rare, and was here twice).
  defp action_pills(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <.pill
        event="toggle_saved"
        on={@lib.saved?}
        icon="bookmark"
        on_class="btn-primary"
        label={if @lib.saved?, do: "Saved", else: "Save"}
        title={if @lib.saved?, do: "Saved for later (click to remove)", else: "Save for later"}
      />
      <%!-- A film is watched or not; a series is completed or not (episodes below one by one).
            The same button marks and unmarks. --%>
      <.pill
        event="toggle_watched"
        on={watched_state?(@title, @lib)}
        icon="check-circle"
        on_class="btn-success"
        busy={@busy}
        label={pill_watched_label(@title, @lib)}
        title={
          if watched_state?(@title, @lib),
            do: "#{watched_label(@title, @lib)} (click to mark as not watched)",
            else: watched_label(@title, @lib)
        }
      />

      <%!-- TMDB's average, and — once you have rated it — yours beside it in another colour. --%>
      <button
        phx-click={JS.show(to: "#rate-sheet", display: "flex")}
        class="btn btn-sm h-10 w-40 gap-2 rounded-full px-4"
        title={if @rating.value, do: "Your rating — click to change it", else: "Rate it on TMDB"}
        aria-label="Rate it"
      >
        <.icon name="hero-star-solid" class="h-4 w-4 text-warning" />
        <span class="font-semibold text-warning">{avg_text(@title)}</span>
        <span :if={@rating.value} class="font-semibold text-info">{fmt_rating(@rating.value)}</span>
        <span :if={!@rating.value} class="text-base-content/60">Rate</span>
      </button>
    </div>
    """
  end

  attr :event, :string, required: true
  attr :on, :boolean, required: true
  attr :icon, :string, required: true
  attr :on_class, :string, required: true
  attr :label, :string, required: true
  attr :title, :string, required: true
  attr :busy, :boolean, default: false

  defp pill(assigns) do
    ~H"""
    <button
      phx-click={@event}
      disabled={@busy}
      class={["btn btn-sm h-10 w-40 gap-2 whitespace-nowrap rounded-full px-4", @on && @on_class]}
      title={@title}
      aria-label={@title}
    >
      <span :if={@busy} class="loading loading-spinner loading-sm"></span>
      <.icon :if={!@busy} name={"hero-#{@icon}#{if @on, do: "-solid"}"} class="h-5 w-5" />
      {@label}
    </button>
    """
  end

  defp avg_text(%{vote: v}) when is_number(v) and v > 0, do: fmt_rating(Float.round(v * 1.0, 1))
  defp avg_text(_), do: "–"

  # 8.0 → "8", 8.5 → "8.5"
  defp provider_name(:mal), do: "MyAnimeList"
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

  # The same, short enough for a pill of one width.
  defp pill_watched_label(%{type: "movie"} = title, lib), do: watched_label(title, lib)
  defp pill_watched_label(_title, %{all_watched?: true}), do: "Completed"
  defp pill_watched_label(_title, _lib), do: "Mark completed"

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
        <.icon name="hero-play-solid" class="h-6 w-6" />
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
      <.icon name="hero-play-solid" class="h-6 w-6" />
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
        <.icon name="hero-play-solid" class="h-6 w-6" />
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
      <span>Connect laev on your shelf to watch here — your Real-Debrid or TorBox account does the streaming.</span>
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
        <form
          :if={@sections != []}
          phx-change="select_season"
          id="season-form"
          class="min-w-0 flex-1"
        >
          <select
            name="season"
            aria-label="Season"
            class="select select-bordered h-12 w-full rounded-xl text-base font-semibold sm:text-lg"
          >
            <option
              :for={sec <- @sections}
              value={sec.key}
              selected={@section && sec.key == @section.key}
              class={
                season_done?(sec, @section, @episodes, @watched, @season_counts) &&
                  "text-base-content/40"
              }
            >
              {season_label(sec, season_done?(sec, @section, @episodes, @watched, @season_counts))}
            </option>
          </select>
        </form>
        <%!-- MyAnimeList rates by season: the season picked is the one rated. --%>
        <button
          :if={@can_play? and @rating.state == :ok and @rating.provider == :mal}
          type="button"
          phx-click={JS.show(to: "#rate-sheet", display: "flex")}
          class="btn h-12 shrink-0 gap-1.5 rounded-xl px-4"
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
            "btn btn-square h-12 w-12 shrink-0 rounded-xl",
            state == :complete && "btn-success",
            state == :up_to_date && "btn-outline btn-success"
          ]}
          title={season_title(state, to_come)}
          aria-label={season_aria(state, to_come)}
        >
          <.icon
            name={if state == :open, do: "hero-check-circle", else: "hero-check-circle-solid"}
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
            "relative flex items-center gap-3 rounded-2xl border border-base-300 bg-base-100 p-3 transition hover:border-base-content/20",
            MapSet.member?(@watched, e.number) && "bg-base-200/60"
          ]}
        >
          <%!-- The whole row is one link to this episode's sources (a stretched link under the two
                buttons), so there is nowhere on it that does nothing. --%>
          <div class={[
            "flex min-w-0 flex-1 gap-3",
            MapSet.member?(@watched, e.number) && "opacity-45 grayscale"
          ]}>
            <div class="hidden h-[4.5rem] w-32 shrink-0 overflow-hidden rounded-xl bg-base-300 sm:block">
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
                "btn btn-square h-12 w-12 rounded-xl",
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
                    do: "hero-check-circle-solid",
                    else: "hero-check-circle"
                }
                class="h-8 w-8"
              />
            </button>
            <.link
              navigate={~p"/sources/tv/#{@title_id}/#{@season}/#{e.number}?#{[auto: 1]}"}
              class="btn btn-primary h-12 w-12 rounded-xl px-0 text-base sm:w-auto sm:px-6"
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

  defp season_label(sec, done?), do: sec.label <> if(done?, do: " ✓", else: "")

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
        class="btn btn-ghost btn-circle btn-sm relative"
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
        class="absolute right-0 top-full z-40 mt-1 hidden w-56 rounded-box border border-base-300 bg-base-100 p-1 shadow-xl"
        phx-click-away={JS.hide(to: "##{@id}")}
        phx-window-keydown={JS.hide(to: "##{@id}")}
        phx-key="escape"
      >
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
  attr :locked?, :boolean, default: false
  attr :mal, :any, default: nil

  # One screen on a phone: the title and its details on top, a large poster with the three icon
  # buttons beside it, the synopsis (tap for the full text and more facts), and Play pinned to
  # the bottom with where it plays just above it. Wider screens use `hero/1`.
  defp phone_hero(assigns) do
    assigns = assign(assigns, :busy?, match?({:working, _}, assigns.phase))

    ~H"""
    <section class={[
      "-mt-4 flex h-[calc(100svh-4.5rem-1px)] flex-col gap-3 pb-[calc(7rem+max(0.75rem,env(safe-area-inset-bottom)))] sm:hidden",
      @locked? && "-mb-9"
    ]}>
      <div class="relative flex shrink-0 items-start gap-2">
        <div class="min-w-0 flex-1">
          <h1 class="text-2xl font-bold leading-tight tracking-tight">{@title.title}</h1>
          <p class="mt-0.5 text-xs text-base-content/60">{meta(@title)}</p>
        </div>

        <.more_menu id="more-menu-phone" title={@title} linked?={@linked?} lib={@lib} mal={@mal} />
      </div>

      <%!-- The poster takes all the height there is between the title and the synopsis; the
            three buttons are a strip against the right edge of the screen. --%>
      <%!-- The row is a size container: the poster is sized in its units (two thirds of its height,
            but never more than 62% of its width), so it never depends on its own content — a
            percentage height plus an aspect ratio collapses to nothing in Safari. --%>
      <%!-- The poster row and the synopsis are one block, sized in its units (a size container): the
            row is as tall as the poster can be — the block's height less the synopsis, or what its
            width allows — and the synopsis follows it directly, so there is no gap between them. --%>
      <div class="flex min-h-0 flex-1 flex-col gap-3 [container-type:size]">
        <div class="flex h-[min(calc(100cqh-7rem),105cqw)] shrink-0 gap-3 px-4">
          <div class="relative aspect-[2/3] w-[min(calc((100cqh-7rem)*0.66667),70cqw)] shrink-0 self-start overflow-hidden rounded-2xl bg-base-300 shadow-xl ring-1 ring-black/10">
            <img
              :if={@title.poster}
              src={Roki.Images.local(@title.poster)}
              alt={@title.title}
              class="absolute inset-0 h-full w-full object-cover"
            />
          </div>

          <%!-- Icons only: saved, watched, rating — three tiles sharing the poster's height, the icon
              centred in each. The state is the colour; the label is the tooltip. --%>
          <%!-- As tall as the poster, never taller: the poster's height is 1.5 x its width, which on a
              narrow screen is the width cap and not the row's height. --%>
          <div
            :if={@linked?}
            class="flex h-[min(calc(100cqh-7rem),105cqw)] min-w-0 flex-1 flex-col gap-2 self-start"
          >
            <.round_btn
              event="toggle_saved"
              on={@lib.saved?}
              icon="bookmark"
              label={if @lib.saved?, do: "Saved for later (tap to remove)", else: "Save for later"}
              on_class="btn-primary"
            />
            <.round_btn
              event="toggle_watched"
              on={watched_state?(@title, @lib)}
              icon="check-circle"
              label={
                if watched_state?(@title, @lib),
                  do: "Completed (tap to unmark)",
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
          <span class="line-clamp-4 text-sm text-base-content/80">{@title.overview}</span>
          <span class="flex items-center gap-1 text-xs font-medium text-primary">
            More <.icon name="hero-chevron-up-micro" class="h-4 w-4" />
          </span>
        </button>
      </div>

      <%!-- Glued to the bottom edge of the screen: where it plays, then Play. --%>
      <div class="fixed inset-x-0 bottom-0 z-30 space-y-2 rounded-t-3xl border-t border-base-300 bg-base-100/95 px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-2 shadow-[0_-8px_24px_-12px_rgba(0,0,0,0.25)] backdrop-blur [&_.btn]:rounded-2xl">
        <div :if={@linked?} class="flex items-center justify-between gap-3">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/50">Watch in</span>
          <Layouts.player_switch size="sm" />
        </div>
        <.play_button
          split?
          title={@title}
          play={@play}
          resume={@resume}
          resume_secs={@resume_secs}
          busy?={@busy?}
          class="h-14 w-full text-xl"
        />
      </div>

      <.about_sheet title={@title} />

      <%!-- While the page is exactly one screen, it is not a page you can drag: the document is
            locked in place (and unlocked as soon as there is more below, e.g. after Play). --%>
      <style :if={@locked?}>
        @media (max-width: 639px) {
          html, body { overflow: hidden; height: 100%; overscroll-behavior: none; }
        }
      </style>
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
      class={[
        "btn h-auto min-h-0 w-full flex-1 rounded-2xl px-0 shadow-sm",
        if(@on, do: @on_class, else: "border-base-300 bg-base-100")
      ]}
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
      class="fixed inset-0 z-[70] !m-0 hidden items-end bg-black/50"
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
      class="btn h-auto min-h-0 w-full flex-1 flex-col gap-0 rounded-2xl border-base-300 bg-base-100 px-0 leading-tight shadow-sm"
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
              )} votes</span><span :if={@rating.provider == :mal}> · your score goes to MyAnimeList</span>
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

        <div :if={@rating.state == :no_account and @rating.provider != :mal} class="mt-4 space-y-3">
          <p class="text-sm text-base-content/70">
            Your rating is saved on your own TMDB account, so it is yours and only yours. You
            have not linked one yet: it takes a minute, TMDB is free, and you come straight back
            here to rate.
          </p>
          <a
            href={~p"/tmdb/link?#{[return: "/title/#{@title.type}/#{@title.id}"]}"}
            class="btn btn-primary btn-sm"
          >
            Link my TMDB account
          </a>
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
