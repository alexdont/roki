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
        rating: %{state: :loading, value: nil, provider: :tmdb},
        rate_mal: nil,
        rating_error: nil,
        similar: [],
        similar_seen: MapSet.new(),
        study: nil,
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

    if connected?(socket),
      do: start_async(socket, :title, fn -> load_title(type, id, uuid) end),
      else: socket
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
  def handle_event("study_go", %{"lang" => lang, "subs" => subs}, socket) do
    %{uuid: uuid, type: type, id: id, play: play} = socket.assigns

    if uuid && socket.assigns.linked? do
      Roki.Study.put(uuid, type, id, lang, subs)

      path =
        if type == "movie",
          do: ~p"/watch/movie/#{id}?#{[study: 1]}",
          else: ~p"/watch/tv/#{id}/#{play.season}/#{play.episode}?#{[study: 1]}"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

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
     |> start_async(:similar, fn ->
       # What this person has watched, saved and rated of them, worked out alongside.
       with {:ok, cards} <- Roki.Similar.for_title(uuid, title.type, title.id) do
         {:ok, Roki.Laev.annotate(uuid, cards), Roki.Laev.seen_keys(uuid, cards)}
       end
     end)
     |> start_async(:study, fn -> if uuid, do: study_choice(uuid, title) end)
     |> select()}
  end

  def handle_async(:similar, {:ok, {:ok, cards, seen}}, socket),
    do: {:noreply, assign(socket, similar: cards, similar_seen: seen)}

  def handle_async(:similar, _other, socket), do: {:noreply, socket}

  def handle_async(:study, {:ok, %{} = choice}, socket),
    do: {:noreply, assign(socket, :study, choice)}

  def handle_async(:study, _other, socket), do: {:noreply, socket}

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

  def handle_async(:lib_reload, {:ok, %{} = lib}, socket), do: {:noreply, assign(socket, :lib, lib)}
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
        />

        <.study_sheet :if={@linked? and @study} title={@title} study={@study} />

        <.access_notice uuid={@uuid} linked?={@linked?} />

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

        <%!-- What people here have said about it: comments, a thread of replies. One thread for the
              title, the same for everyone. Plain text, so it needs no editor script. --%>
        <section :if={@title.type in ["movie", "tv"]} class="space-y-3" aria-label="Comments">
          <.live_component
            module={PhoenixKitComments.Web.CommentsComponent}
            id="title-comments"
            resource_type="title"
            resource_uuid={Roki.Social.title_uuid(@title.type, @title.id)}
            current_user={assigns[:phoenix_kit_current_user]}
            rich_text={false}
          />
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

  # The top of the episodes page: where you are, and a way back to the title.
  defp episodes_header(assigns) do
    ~H"""
    <div class="relative flex items-center gap-4">
      <.link navigate={~p"/title/tv/#{@title.id}"} class="shrink-0" aria-label="Back to the title">
        <img
          :if={@title.poster}
          src={Roki.Images.local(@title.poster)}
          alt={@title.title}
          class="aspect-[2/3] w-16 rounded-lg bg-base-300 object-cover shadow sm:w-20"
        />
      </.link>
      <div class="min-w-0 flex-1">
        <.link
          navigate={~p"/title/tv/#{@title.id}"}
          class="text-sm text-base-content/60 hover:text-primary"
        >
          ← Back to the title
        </.link>
        <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">{@title.title}</h1>
      </div>
      <.link
        :if={@play.continue?}
        navigate={~p"/sources/tv/#{@title.id}/#{@play.season}/#{@play.episode}?#{[auto: 1]}"}
        class="btn btn-primary"
      >
        <.icon name="hero-play-solid" class="h-5 w-5" /> {@play.verb} {@play.label}
      </.link>
      <.more_menu id="more-menu-eps" title={@title} linked?={@linked?} lib={@lib} mal={@mal} />
    </div>
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

  defp hero(assigns) do
    ~H"""
    <section class="hidden gap-6 sm:flex">
      <div class="w-[8.5rem] shrink-0 space-y-3 sm:w-56 sm:space-y-4">
        <img
          :if={@title.poster}
          src={Roki.Images.local(@title.poster)}
          alt={@title.title}
          class="aspect-[2/3] w-full rounded-box bg-base-300 object-cover shadow-lg"
        />
        <div :if={!@title.poster} class="aspect-[2/3] w-full rounded-box bg-base-300"></div>

        <%!-- Under the poster, well away from Play: a slip here should not save or hold a title. --%>
        <.library_buttons :if={@linked?} title={@title} lib={@lib} busy={@lib_busy} rating={@rating} />
      </div>

      <div class="min-w-0 flex-1 space-y-3">
        <div class="relative flex items-start gap-3">
          <div class="min-w-0 flex-1">
            <h1 class="text-xl font-bold leading-tight tracking-tight sm:text-4xl">{@title.title}</h1>
            <p class="text-sm text-base-content/60">
              {meta(@title)}
            </p>
            <p :if={@title.tagline} class="mt-1 italic text-base-content/60">{@title.tagline}</p>
          </div>
          <.more_menu id="more-menu-desk" title={@title} linked?={@linked?} lib={@lib} mal={@mal} />
        </div>

        <p
          :if={@title.overview}
          class="line-clamp-6 max-w-3xl text-sm text-base-content/80 sm:line-clamp-none sm:text-base"
        >
          {@title.overview}
        </p>

        <div class="space-y-3 pt-2">
          <%!-- Where it plays, then the button: one decision above the other. --%>
          <div :if={@linked? and @title.type == "movie"} class="flex">
            <.sources_link title={@title} />
          </div>

          <div class="flex flex-wrap items-center gap-3">
            <.play_button
              title={@title}
              play={@play}
              resume={@resume}
              resume_secs={@resume_secs}
              busy?={match?({:working, _}, @phase)}
              class="h-12 w-full text-lg sm:h-14 sm:w-auto sm:min-w-[15rem] sm:text-xl"
            />
            <button
              :if={@linked? and @study}
              type="button"
              phx-click={JS.show(to: "#study-sheet", display: "flex")}
              class="btn btn-outline hidden h-12 gap-2 lg:inline-flex sm:h-14"
              title="Watch this in languages you choose, leaving your settings alone"
            >
              <.icon name="hero-academic-cap" class="h-5 w-5" /> Study
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

  # The icon classes below are built from a name, which Tailwind cannot see, so they are spelled
  # out here: hero-bookmark hero-bookmark-solid hero-pause-circle hero-pause-circle-solid
  # hero-check-circle hero-check-circle-solid
  # What the terminal app has on a title: saved for later, on hold, watched (and back) — as icons,
  # the same ones and the same colours as the hover card on a poster; the words are the tooltip.
  defp library_buttons(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 sm:gap-3">
      <div class="flex gap-2 sm:gap-3">
        <.lib_icon
          event="toggle_saved"
          on={@lib.saved?}
          icon="bookmark"
          on_class="btn-primary"
          label={if @lib.saved?, do: "Saved for later (click to remove)", else: "Save for later"}
        />
        <.lib_icon
          :if={not @title.anime?}
          event="toggle_hold"
          on={@lib.held?}
          icon="pause-circle"
          on_class="btn-warning"
          label={if @lib.held?, do: "On hold (click to take it off)", else: "Put on hold"}
        />
        <%!-- A film is watched or not; a series is completed or not (episodes below one by one).
              The same button marks and unmarks. --%>
        <.lib_icon
          event="toggle_watched"
          on={watched_state?(@title, @lib)}
          icon="check-circle"
          on_class="btn-success"
          busy={@busy}
          label={
            if watched_state?(@title, @lib),
              do: "#{watched_label(@title, @lib)} (click to mark as not watched)",
              else: watched_label(@title, @lib)
          }
        />
      </div>

      <%!-- TMDB's average, and — once you have rated it — yours beside it in another colour. --%>
      <button
        phx-click={JS.show(to: "#rate-sheet", display: "flex")}
        class="btn h-auto min-h-10 w-full justify-center gap-3 px-3 py-2 text-xs sm:h-12 sm:px-4 sm:text-sm"
        title={if @rating.value, do: "Your rating — click to change it", else: "Rate it on TMDB"}
        aria-label="Rate it"
      >
        <span class="flex items-center gap-1.5">
          <.icon name="hero-star-solid" class="h-4 w-4 shrink-0 text-warning sm:h-5 sm:w-5" />
          <span class="font-semibold text-warning">{avg_text(@title)}</span>
        </span>
        <span :if={@rating.value} class="font-semibold text-info">{fmt_rating(@rating.value)}</span>
      </button>
    </div>
    """
  end

  attr :event, :string, required: true
  attr :on, :boolean, required: true
  attr :icon, :string, required: true
  attr :on_class, :string, required: true
  attr :label, :string, required: true
  attr :busy, :boolean, default: false

  defp lib_icon(assigns) do
    ~H"""
    <button
      phx-click={@event}
      disabled={@busy}
      class={["btn h-12 min-h-0 flex-1 px-0", @on && @on_class]}
      title={@label}
      aria-label={@label}
    >
      <span :if={@busy} class="loading loading-spinner loading-sm"></span>
      <.icon :if={!@busy} name={"hero-#{@icon}#{if @on, do: "-solid"}"} class="h-6 w-6" />
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
  defp study_choice(uuid, title) do
    case Roki.Study.get(uuid, title.type, title.id) do
      %{"lang" => lang, "subs" => subs} ->
        %{lang: lang, subs: subs}

      nil ->
        Roki.Laev.run(uuid, fn ->
          %{lang: Laev.Config.lang(), subs: Laev.Config.subs_lang() || "off"}
        end)
    end
  end

  # What a score means is laev's own list (`Laev.Ratings`); the colour it is drawn in runs red at the
  # bottom through green at 7 to gold at 10. `assets/js/app.js` (`rokiScore`) does the same while the
  # slider moves, with the words handed to it on the sheet.
  defp score_word(v) when is_number(v), do: Laev.Ratings.score_word(v)

  defp score_color(v) when is_number(v) do
    s = v |> max(1) |> min(10)

    {hue, sat, light} =
      if s <= 7,
        do: {(s - 1) / 6 * 130, 75, 46},
        else: {130 - (s - 7) / 3 * 85, 75 + (s - 7) / 3 * 20, 46 + (s - 7) / 3 * 6}

    "hsl(#{round(hue)} #{round(sat)}% #{round(light)}%)"
  end

  defp score_track do
    # The slider runs 0.5 to 10, so a score sits at (score - 0.5) / 9.5 along it.
    stops = Enum.map_join(1..10, ", ", &"#{score_color(&1)} #{round((&1 - 0.5) / 9.5 * 100)}%")
    "linear-gradient(90deg, #{stops})"
  end

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

  defp episodes(assigns) do
    ~H"""
    <section class="space-y-4">
      <h2 class="text-xl font-semibold">Episodes</h2>

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
            class="select select-bordered select-primary h-14 w-full text-lg font-semibold"
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
          class="btn h-14 shrink-0 gap-1.5 px-4"
          title="Rate this season on MyAnimeList"
          aria-label="Rate this season"
        >
          <.icon name="hero-star" class="h-6 w-6" />
          <span :if={@rating.value} class="font-semibold text-info">{fmt_rating(@rating.value)}</span>
          <span :if={!@rating.value} class="hidden sm:inline">Rate</span>
        </button>
        <button
          :if={@can_play? and is_list(@episodes) and @episodes != []}
          phx-click="toggle_season"
          class={[
            "btn btn-square h-14 w-14 shrink-0",
            season_all_watched?(@episodes, @watched) && "btn-success"
          ]}
          title={
            if season_all_watched?(@episodes, @watched),
              do: "Season watched — click to unmark",
              else: "Mark the whole season watched"
          }
          aria-label={
            if season_all_watched?(@episodes, @watched),
              do: "Unmark season watched",
              else: "Mark season watched"
          }
        >
          <.icon
            name={
              if season_all_watched?(@episodes, @watched),
                do: "hero-check-circle-solid",
                else: "hero-check-circle"
            }
            class="h-8 w-8"
          />
        </button>
      </div>

      <div :if={@episodes == nil} class="space-y-2" aria-busy="true">
        <div :for={_ <- 1..4} class="skeleton h-20 w-full rounded-box"></div>
      </div>
      <p :if={@episodes == []} class="text-base-content/60">No episodes listed for this season.</p>

      <ul :if={is_list(@episodes)} class="divide-y divide-base-300 rounded-box border border-base-300">
        <li
          :for={e <- @episodes}
          class={[
            "relative flex items-center gap-3 p-3",
            MapSet.member?(@watched, e.number) && "bg-base-200"
          ]}
        >
          <%!-- The whole row is one link to this episode's sources (a stretched link under the two
                buttons), so there is nowhere on it that does nothing. --%>
          <div class={[
            "flex min-w-0 flex-1 gap-3",
            MapSet.member?(@watched, e.number) && "opacity-45 grayscale"
          ]}>
            <div class="hidden h-[4.5rem] w-32 shrink-0 overflow-hidden rounded bg-base-300 sm:block">
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
                "btn btn-square h-14 w-14",
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
              class="btn btn-primary h-14 w-14 px-0 text-base sm:w-auto sm:px-6"
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

  defp season_all_watched?(episodes, watched) do
    out = for e <- episodes, e.aired?, do: e.number
    out != [] and Enum.all?(out, &MapSet.member?(watched, &1))
  end

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
    <div class="shrink-0">
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
      "-mt-4 flex h-[calc(100svh-4.5rem-1px)] flex-col gap-3 pb-[calc(5rem+max(0.75rem,env(safe-area-inset-bottom)))] sm:hidden",
      @locked? && "-mb-9"
    ]}>
      <div class="relative flex shrink-0 items-start gap-2">
        <div class="min-w-0 flex-1">
          <h1 class="text-xl font-bold leading-tight">{@title.title}</h1>
          <p class="text-xs text-base-content/60">{meta(@title)}</p>
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
          <div class="relative aspect-[2/3] w-[min(calc((100cqh-7rem)*0.66667),70cqw)] shrink-0 self-start overflow-hidden rounded-box bg-base-300 shadow-lg">
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
      <div class="fixed inset-x-0 bottom-0 z-30 space-y-2 border-t border-base-300 bg-base-100/95 px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-3 backdrop-blur">
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
  attr :study, :map, required: true

  # Study mode, from a desktop: which languages to watch this title in, without touching the
  # account's settings. What was chosen last time is already filled in.
  defp study_sheet(assigns) do
    assigns =
      assign(assigns,
        audio: Roki.Languages.choices(assigns.study.lang),
        subs: Roki.Languages.choices(assigns.study.subs)
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
  defp rate_sheet(assigns) do
    ~H"""
    <div
      id="rate-sheet"
      data-words={Jason.encode!(for {n, w} <- Laev.Ratings.score_words(), into: %{}, do: {n, w})}
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
          <a href={~p"/tmdb/link?#{[return: "/title/#{@title.type}/#{@title.id}"]}"} class="btn btn-primary btn-sm">
            Link my TMDB account
          </a>
        </div>
        <p :if={@rating.state == :no_account and @rating.provider == :mal} class="mt-4 text-sm text-base-content/70">
          Anime ratings go to MyAnimeList. Connect your account on the
          <.link navigate={~p"/account/services"} class="link">services page</.link>, then rate here.
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
              class="text-sm font-semibold uppercase tracking-wider"
              style={"color: #{score_color(@rating.value || 7)}"}
            >
              {score_word(@rating.value || 7)}
            </p>
            <span
              id="rate-out"
              class="text-5xl font-bold"
              style={"color: #{score_color(@rating.value || 7)}"}
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
            style={"--thumb: #{score_color(@rating.value || 7)}; --track: #{score_track()}"}
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
            Your rating: <span class="font-semibold text-info">{fmt_rating(@rating.value)}</span>
          </p>
        </form>

        <p :if={@rating.state == :loading} class="mt-4 text-sm text-base-content/60">Loading…</p>
        <p :if={@error} class="mt-3 text-sm text-error">{@error}</p>
      </div>
    </div>
    """
  end

  attr :title, :map, required: true

  # Straight to the sources (a film) or the episodes (a series), without starting anything.
  defp sources_link(assigns) do
    ~H"""
    <.link
      navigate={
        if @title.type == "movie",
          do: ~p"/sources/movie/#{@title.id}",
          else: ~p"/title/tv/#{@title.id}/episodes"
      }
      class="btn btn-xs sm:btn-sm"
    >
      <.icon name="hero-queue-list" class="h-4 w-4" />
      {if @title.type == "movie", do: "Sources", else: "Episodes"}
    </.link>
    """
  end
end
