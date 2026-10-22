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

  import RokiWeb.WatchComponents, only: [mode_switch: 1]

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
        rating: %{state: :loading, value: nil},
        rating_error: nil,
        page_title: "Watch",
        title: nil,
        title_error: nil,
        resume: nil,
        resume_secs: nil,
        req_season: nil,
        season: nil,
        episodes: nil,
        watched: MapSet.new(),
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

  defp rating_state({:ok, value}), do: %{state: :ok, value: value}
  defp rating_state(:no_account), do: %{state: :no_account, value: nil}
  defp rating_state(_), do: %{state: :loading, value: nil}

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
      rating = if linked?, do: Watch.my_rating(uuid, title)

      secs = if linked?, do: left_at(uuid, title)

      {:ok, title, resume, cached, lib, rating, secs}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:req_season, to_int(params["s"])) |> select()}
  end

  # On the episodes page, settle which season is on screen and load its episodes.
  defp select(%{assigns: %{live_action: :episodes, title: %{} = title}} = socket) do
    %{resume: resume, req_season: req} = socket.assigns
    numbers = Enum.map(title.seasons, & &1.number)
    wanted = req || (resume && resume["season"]) || List.first(numbers)
    season = if wanted in numbers, do: wanted, else: List.first(numbers)

    if season != socket.assigns.season or socket.assigns.episodes == nil do
      load_episodes(assign(socket, season: season, episodes: nil), season)
    else
      socket
    end
  end

  defp select(socket), do: socket

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

  # Play opens the next page of the flow; nothing starts here.
  @impl true
  def handle_event("play", _params, %{assigns: %{type: "movie", id: id}} = socket),
    do: {:noreply, push_navigate(socket, to: ~p"/sources/movie/#{id}?#{[auto: 1]}")}

  def handle_event("play", _params, %{assigns: %{id: id}} = socket),
    do: {:noreply, push_navigate(socket, to: ~p"/title/tv/#{id}/episodes")}

  def handle_event("select_season", %{"season" => s}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/title/tv/#{socket.assigns.id}/episodes?#{[s: s]}")}

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
    %{uuid: uuid, title: title} = socket.assigns

    case Float.parse(to_string(v)) do
      {value, _} ->
        {:noreply,
         start_async(socket, :rating, fn -> {:rate, Watch.rate(uuid, title, value)} end)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("rate", _params, socket), do: {:noreply, socket}

  def handle_event("clear_rating", _params, %{assigns: %{rating: %{state: :ok}}} = socket) do
    %{uuid: uuid, title: title} = socket.assigns
    {:noreply, start_async(socket, :rating, fn -> {:clear, Watch.clear_rating(uuid, title)} end)}
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
  def handle_async(:title, {:ok, {:ok, title, resume, cached, lib, rating, secs}}, socket) do
    socket =
      assign(socket,
        title: title,
        resume: resume,
        resume_secs: secs,
        cached: cached,
        lib: lib || socket.assigns.lib,
        rating: rating_state(rating),
        page_title: title.title
      )

    {:noreply, select(socket)}
  end

  def handle_async(:title, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :title_error, reason || true)}

  def handle_async(:title, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :title_error, reason)}

  def handle_async(:rating, {:ok, {:rate, {:ok, value}}}, socket),
    do: {:noreply, assign(socket, rating: %{state: :ok, value: value}, rating_error: nil)}

  def handle_async(:rating, {:ok, {:clear, :ok}}, socket),
    do: {:noreply, assign(socket, rating: %{state: :ok, value: nil}, rating_error: nil)}

  def handle_async(:rating, _other, socket),
    do: {:noreply, assign(socket, :rating_error, "TMDB did not take that. Try again.")}

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

  def handle_async(:episodes, {:ok, {:ok, season, eps, watched}}, socket) do
    if season == socket.assigns.season,
      do: {:noreply, assign(socket, episodes: eps, watched: watched)},
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
        />

        <.rate_sheet :if={@linked?} title={@title} rating={@rating} error={@rating_error} />

        <.hero
          rating={@rating}
          title={@title}
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

        <.access_notice uuid={@uuid} linked?={@linked?} />

        <%!-- On a phone the Play bar is fixed to the screen's bottom; leave room under the page. --%>
        <div :if={!@locked?} class="h-36 sm:hidden" aria-hidden="true"></div>
      </div>

      <div :if={@title && @live_action == :episodes} class="space-y-6">
        <.episodes_header title={@title} resume={@resume} />
        <.access_notice uuid={@uuid} linked?={@linked?} />

        <.episodes
          title={@title}
          season={@season}
          episodes={@episodes}
          watched={@watched}
          cached={@cached}
          title_id={@id}
          can_play?={@linked?}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :title, :map, required: true
  attr :resume, :any, default: nil

  # The top of the episodes page: where you are, and a way back to the title.
  defp episodes_header(assigns) do
    ~H"""
    <div class="flex items-center gap-4">
      <.link navigate={~p"/title/tv/#{@title.id}"} class="shrink-0" aria-label="Back to the title">
        <img
          :if={@title.poster}
          src={@title.poster}
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
        :if={match?(%{"season" => s, "episode" => e} when is_integer(s) and is_integer(e), @resume)}
        navigate={
          ~p"/sources/tv/#{@title.id}/#{@resume["season"]}/#{@resume["episode"]}?#{[auto: 1]}"
        }
        class="btn btn-primary"
      >
        <.icon name="hero-play-solid" class="h-5 w-5" />
        Continue S{@resume["season"]} · E{@resume["episode"]}
      </.link>
    </div>
    """
  end

  attr :cached?, :boolean, default: false
  attr :title, :map, required: true
  attr :resume, :any, default: nil
  attr :resume_secs, :any, default: nil
  attr :phase, :any, required: true
  attr :season, :any, default: nil
  attr :mode, :atom, required: true
  attr :linked?, :boolean, default: false
  attr :lib, :map, required: true
  attr :lib_busy, :boolean, default: false
  attr :rating, :map, required: true

  defp hero(assigns) do
    ~H"""
    <section class="hidden gap-6 sm:flex">
      <div class="w-[8.5rem] shrink-0 space-y-3 sm:w-56 sm:space-y-4">
        <img
          :if={@title.poster}
          src={@title.poster}
          alt={@title.title}
          class="aspect-[2/3] w-full rounded-box bg-base-300 object-cover shadow-lg"
        />
        <div :if={!@title.poster} class="aspect-[2/3] w-full rounded-box bg-base-300"></div>

        <%!-- Under the poster, well away from Play: a slip here should not save or hold a title. --%>
        <.library_buttons :if={@linked?} title={@title} lib={@lib} busy={@lib_busy} rating={@rating} />
      </div>

      <div class="min-w-0 flex-1 space-y-3">
        <div>
          <h1 class="text-xl font-bold leading-tight tracking-tight sm:text-4xl">{@title.title}</h1>
          <p class="text-sm text-base-content/60">
            {meta(@title)}
          </p>
          <p :if={@title.tagline} class="mt-1 italic text-base-content/60">{@title.tagline}</p>
        </div>

        <p
          :if={@title.overview}
          class="line-clamp-6 max-w-3xl text-sm text-base-content/80 sm:line-clamp-none sm:text-base"
        >
          {@title.overview}
        </p>

        <div class="space-y-3 pt-2">
          <%!-- Where it plays, then the button: one decision above the other. --%>
          <div :if={@linked?} class="flex flex-wrap items-center justify-around gap-3">
            <.sources_link title={@title} />
            <.mode_switch mode={@mode} />
          </div>

          <div class="flex flex-wrap items-center gap-3">
            <button
              phx-click="play"
              class="btn btn-primary btn-lg h-12 w-full gap-2 px-4 text-lg shadow-md sm:h-14 sm:w-auto sm:min-w-[15rem] sm:px-10 sm:text-xl"
              disabled={match?({:working, _}, @phase)}
            >
              <.icon name="hero-play-solid" class="h-6 w-6" />
              {if @title.type == "movie", do: play_label(@resume_secs), else: play_label_tv(@resume)}
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

  # What the terminal app has on a title: watched (and back), saved for later, on hold.
  defp library_buttons(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 sm:gap-3">
      <button
        phx-click="toggle_saved"
        class={[
          "btn h-auto min-h-10 w-full justify-start gap-2 px-3 py-2 text-left text-xs leading-tight sm:h-12 sm:gap-2.5 sm:px-4 sm:text-sm",
          @lib.saved? && "btn-primary"
        ]}
        title={if @lib.saved?, do: "Click to remove it from saved", else: "Keep it for later"}
      >
        <.icon
          name={if @lib.saved?, do: "hero-bookmark-solid", else: "hero-bookmark"}
          class="h-4 w-4 shrink-0 sm:h-5 sm:w-5"
        />
        {if @lib.saved?, do: "Saved for later", else: "Save for later"}
      </button>

      <button
        :if={not @title.anime?}
        phx-click="toggle_hold"
        class={[
          "btn h-auto min-h-10 w-full justify-start gap-2 px-3 py-2 text-left text-xs leading-tight sm:h-12 sm:gap-2.5 sm:px-4 sm:text-sm",
          @lib.held? && "btn-warning"
        ]}
        title={
          if @lib.held?, do: "Click to take it off hold", else: "Put it down without finishing it"
        }
      >
        <.icon
          name={if @lib.held?, do: "hero-pause-circle-solid", else: "hero-pause-circle"}
          class="h-4 w-4 shrink-0 sm:h-5 sm:w-5"
        />
        {if @lib.held?, do: "On hold", else: "Put on hold"}
      </button>

      <%!-- A film is watched or not; a series is "all watched" or not (episodes below one by one).
            The same button marks and unmarks. --%>
      <button
        :if={@title.type == "movie" or not @title.anime?}
        phx-click="toggle_watched"
        disabled={@busy}
        class={[
          "btn h-auto min-h-10 w-full justify-start gap-2 px-3 py-2 text-left text-xs leading-tight sm:h-12 sm:gap-2.5 sm:px-4 sm:text-sm",
          watched_state?(@title, @lib) && "btn-success"
        ]}
        title={
          if watched_state?(@title, @lib),
            do: "Click to mark as not watched",
            else: "Mark it as watched"
        }
      >
        <span :if={@busy} class="loading loading-spinner loading-xs"></span>
        <.icon
          :if={!@busy}
          name={
            if watched_state?(@title, @lib), do: "hero-check-circle-solid", else: "hero-check-circle"
          }
          class="h-4 w-4 shrink-0 sm:h-5 sm:w-5"
        />
        {watched_label(@title, @lib)}
      </button>

      <%!-- TMDB's average, and — once you have rated it — yours beside it in another colour. --%>
      <button
        phx-click={JS.show(to: "#rate-sheet", display: "flex")}
        class="btn h-auto min-h-10 w-full justify-between gap-2 px-3 py-2 text-xs sm:h-12 sm:px-4 sm:text-sm"
        title="Rate it on TMDB"
      >
        <span class="flex items-center gap-1.5">
          <.icon name="hero-star-solid" class="h-4 w-4 shrink-0 text-warning sm:h-5 sm:w-5" />
          <span class="font-semibold text-warning">{avg_text(@title)}</span>
        </span>
        <span :if={@rating.value} class="font-semibold text-info">You {fmt_rating(@rating.value)}</span>
        <span :if={!@rating.value} class="text-base-content/60">Rate</span>
      </button>
    </div>
    """
  end

  defp avg_text(%{vote: v}) when is_number(v) and v > 0, do: fmt_rating(Float.round(v * 1.0, 1))
  defp avg_text(_), do: "–"

  # 8.0 → "8", 8.5 → "8.5"
  defp fmt_rating(v) when is_number(v) do
    if v == trunc(v),
      do: Integer.to_string(trunc(v)),
      else: :erlang.float_to_binary(v * 1.0, decimals: 1)
  end

  defp watched_state?(%{type: "movie"}, lib), do: lib.watched?
  defp watched_state?(_title, lib), do: lib.all_watched?

  defp watched_label(%{type: "movie"}, %{watched?: true}), do: "Watched"
  defp watched_label(%{type: "movie"}, _lib), do: "Mark watched"
  defp watched_label(_title, %{all_watched?: true}), do: "All watched"
  defp watched_label(_title, _lib), do: "Mark all watched"

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

  defp play_label_tv(%{"season" => s, "episode" => e}) when is_integer(s) and is_integer(e),
    do: "Continue S#{s} · E#{e}"

  defp play_label_tv(_), do: "Start"

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
  attr :cached, :any, required: true
  attr :title_id, :integer, required: true
  attr :can_play?, :boolean, default: false

  defp episodes(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex flex-wrap items-center gap-3">
        <h2 class="flex-1 text-xl font-semibold">Episodes</h2>
        <button
          :if={@can_play? and is_list(@episodes) and @episodes != []}
          phx-click="toggle_season"
          class="btn btn-sm gap-1.5"
        >
          <.icon name="hero-check-circle" class="h-4 w-4" />
          {if season_all_watched?(@episodes, @watched),
            do: "Unmark season",
            else: "Mark season watched"}
        </button>
        <form :if={length(@title.seasons) > 1} phx-change="select_season" id="season-form">
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
          class={["flex gap-3 p-3", false]}
        >
          <div class="hidden h-[4.5rem] w-32 shrink-0 overflow-hidden rounded bg-base-300 sm:block">
            <img :if={e.still} src={e.still} alt="" loading="lazy" class="h-full w-full object-cover" />
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <span class="font-medium">{e.number}. {e.name}</span>
              <span :if={MapSet.member?(@watched, e.number)} class="badge badge-sm badge-success">Watched</span>
              <span
                :if={MapSet.member?(@cached, {"tv", @title_id, @season, e.number})}
                class="badge badge-sm badge-success badge-outline"
              >
                ⚡ cached
              </span>
            </div>
            <div class="text-xs text-base-content/60">
              {[e.air_date, e.minutes && "#{e.minutes} min"] |> Enum.filter(& &1) |> Enum.join(" · ")}
              <span :if={not e.aired?}> · not out yet</span>
            </div>
            <p :if={e.overview} class="mt-1 line-clamp-2 text-sm text-base-content/70">
              {e.overview}
            </p>
          </div>
          <div class="flex shrink-0 items-center gap-1 self-center">
            <button
              :if={@can_play? and e.aired?}
              phx-click="toggle_episode"
              phx-value-season={@season}
              phx-value-episode={e.number}
              class={[
                "btn btn-sm btn-ghost btn-square",
                MapSet.member?(@watched, e.number) && "text-success"
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
                class="h-5 w-5"
              />
            </button>
            <.link
              :if={@can_play? and e.aired?}
              navigate={~p"/sources/tv/#{@title_id}/#{@season}/#{e.number}?#{[auto: 1]}"}
              class="btn btn-sm btn-primary"
            >
              <.icon name="hero-play-solid" class="h-4 w-4" /> Play
            </.link>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  defp season_all_watched?(episodes, watched) do
    out = for e <- episodes, e.aired?, do: e.number
    out != [] and Enum.all?(out, &MapSet.member?(watched, &1))
  end

  # ── the phone layout ───────────────────────────────────────────────

  attr :title, :map, required: true
  attr :resume, :any, default: nil
  attr :resume_secs, :any, default: nil
  attr :phase, :any, required: true
  attr :season, :any, default: nil
  attr :mode, :atom, required: true
  attr :linked?, :boolean, default: false
  attr :lib, :map, required: true
  attr :lib_busy, :boolean, default: false
  attr :rating, :map, required: true
  attr :locked?, :boolean, default: false

  # One screen on a phone: the title and its details on top, a large poster with the three icon
  # buttons beside it, the synopsis (tap for the full text and more facts), and Play pinned to
  # the bottom with where it plays just above it. Wider screens use `hero/1`.
  defp phone_hero(assigns) do
    assigns = assign(assigns, :busy?, match?({:working, _}, assigns.phase))

    ~H"""
    <section class={[
      "-mt-4 flex h-[calc(100svh-4.5rem-1px)] flex-col gap-3 pb-[calc(6.5rem+max(0.75rem,env(safe-area-inset-bottom)))] sm:hidden",
      @locked? && "-mb-9"
    ]}>
      <div class="relative flex shrink-0 items-start gap-2">
        <div class="min-w-0 flex-1">
          <h1 class="text-xl font-bold leading-tight">{@title.title}</h1>
          <p class="text-xs text-base-content/60">{meta(@title)}</p>
        </div>

        <%!-- Less used actions live behind the dots: on hold (anime has none: MyAnimeList keeps that). --%>
        <div :if={@linked? and not @title.anime?} class="shrink-0">
          <button
            type="button"
            phx-click={JS.toggle(to: "#more-menu", display: "block")}
            class="btn btn-ghost btn-circle btn-sm relative"
            aria-label="More actions"
            aria-controls="more-menu"
          >
            <.icon name="hero-ellipsis-horizontal" class="h-6 w-6" />
            <span
              :if={@lib.held?}
              class="absolute right-1 top-1 h-2.5 w-2.5 rounded-full bg-warning"
              title="On hold"
            ></span>
          </button>
          <div
            id="more-menu"
            class="absolute right-0 top-full z-40 mt-1 hidden w-56 rounded-box border border-base-300 bg-base-100 p-1 shadow-xl"
            phx-click-away={JS.hide(to: "#more-menu")}
            phx-window-keydown={JS.hide(to: "#more-menu")}
            phx-key="escape"
          >
            <button
              type="button"
              phx-click={JS.push("toggle_hold") |> JS.hide(to: "#more-menu")}
              class="flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left text-sm font-medium hover:bg-base-200"
            >
              <.icon
                name={if @lib.held?, do: "hero-pause-circle-solid", else: "hero-pause-circle"}
                class={["h-5 w-5", @lib.held? && "text-warning"]}
              />
              {if @lib.held?, do: "On hold — take it off", else: "Put on hold"}
            </button>
          </div>
        </div>
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
              src={@title.poster}
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
              :if={@title.type == "movie" or not @title.anime?}
              event="toggle_watched"
              on={watched_state?(@title, @lib)}
              icon="check-circle"
              label={
                if watched_state?(@title, @lib),
                  do: "Watched (tap to unmark)",
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
        <div :if={@linked?} class="flex items-center justify-around gap-2">
          <.sources_link title={@title} />
          <.mode_switch mode={@mode} />
        </div>
        <button
          phx-click="play"
          class="btn btn-primary btn-lg h-14 w-full gap-2 text-xl shadow-md"
          disabled={@busy?}
        >
          <.icon name="hero-play-solid" class="h-6 w-6" />
          {if @title.type == "movie", do: play_label(@resume_secs), else: play_label_tv(@resume)}
        </button>
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
      class="fixed inset-0 z-[70] hidden items-end bg-black/50"
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
  attr :rating, :map, required: true
  attr :error, :string, default: nil

  # Where you rate: TMDB's score for reference, a half-step slider, save or take it back.
  defp rate_sheet(assigns) do
    ~H"""
    <div
      id="rate-sheet"
      class="fixed inset-0 z-[70] hidden items-end bg-black/50 sm:items-center sm:justify-center"
      phx-window-keydown={JS.hide(to: "#rate-sheet")}
      phx-key="escape"
    >
      <div
        class="w-full rounded-t-2xl bg-base-100 p-5 pb-8 shadow-2xl sm:max-w-sm sm:rounded-2xl sm:pb-5"
        phx-click-away={JS.hide(to: "#rate-sheet")}
      >
        <div class="flex items-start gap-3">
          <div class="min-w-0 flex-1">
            <h2 class="text-lg font-bold leading-tight">Rate {@title.title}</h2>
            <p class="text-sm text-base-content/60">
              <span class="font-semibold text-warning">★ {avg_text(@title)}</span>
              on TMDB<span :if={@title.vote_count && @title.vote_count > 0}> · {thousands(
                @title.vote_count
              )} votes</span>
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

        <p :if={@rating.state == :no_account} class="mt-4 text-sm text-base-content/70">
          Ratings are sent with your TMDB account, which isn't linked in laev yet. Link it in the
          terminal app (it comes across with your keys), then rate here.
        </p>

        <form
          :if={@rating.state == :ok}
          id="rate-form"
          phx-submit={JS.push("rate") |> JS.hide(to: "#rate-sheet")}
          class="mt-4 space-y-4"
        >
          <div class="text-center">
            <span id="rate-out" class="text-4xl font-bold text-info">{fmt_rating(@rating.value || 7)}</span>
            <span class="text-lg text-base-content/50"> / 10</span>
          </div>
          <input
            type="range"
            name="value"
            min="0.5"
            max="10"
            step="0.5"
            value={@rating.value || 7}
            oninput="document.getElementById('rate-out').textContent = Number(this.value) % 1 === 0 ? String(Number(this.value)) : Number(this.value).toFixed(1)"
            class="range range-info w-full"
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
