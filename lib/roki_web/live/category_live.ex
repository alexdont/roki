defmodule RokiWeb.CategoryLive do
  @moduledoc """
  `/movies`, `/shows`, `/anime` — one kind of title on a page of its own, in a grid with
  larger posters. Popular (what Featured shows) by default, or newest, oldest, top rated;
  the grid size is a choice at the top right, remembered in the browser. "Load more" adds a
  page as the end of the list comes into view — the Featured page stays short because this is
  where "more" lives.

  Anime can also be listed by season (`?season=fall&year=2026`) and in the order of Anime
  Corner's weekly poll (`?sort=corner&week=3`, the latest week without one): the season's
  anime as people voted them, each poster with its place and share.
  """
  use RokiWeb, :live_view

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Browse

  @titles %{movies: "Movies", shows: "Shows", anime: "Anime"}
  @sizes ~w(s m l)

  # Columns by size; `m` is the default and already larger than the Featured shelves.
  @grids %{
    "s" => "grid-cols-3 sm:grid-cols-5 md:grid-cols-6 lg:grid-cols-8",
    "m" => "grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6",
    "l" => "grid-cols-1 min-[420px]:grid-cols-2 md:grid-cols-3 lg:grid-cols-4"
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    uuid = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)
    kind = socket.assigns.live_action

    {:ok,
     assign(socket,
       kind: kind,
       page_title: @titles[kind],
       uuid: uuid,
       sort: :popular,
       season: nil,
       week: nil,
       genre: nil,
       corner: nil,
       season_count: 12,
       season_error: nil,
       place: RokiWeb.Place.from_params(socket),
       place_y: nil,
       size: stored_size(socket),
       items: [],
       hero: nil,
       page: 0,
       more?: false,
       loading?: true,
       error: nil,
       seen: MapSet.new(),
       upcoming: %{}
     )}
  end

  defp stored_size(socket) do
    params = if connected?(socket), do: get_connect_params(socket) || %{}, else: %{}
    if params["grid"] in @sizes, do: params["grid"], else: "m"
  end

  @impl true
  def handle_params(params, _uri, socket) do
    sort = Browse.sort(params["sort"])
    size = if params["size"] in @sizes, do: params["size"], else: socket.assigns.size

    # Anime can be browsed by quarter (`?season=summer&year=2026`), as in the terminal app.
    season =
      if socket.assigns.kind == :anime, do: Browse.season(params["season"], params["year"])

    # The Anime Corner ranking of one week (`?week=3`, `?week=final`); the latest without.
    week = if sort == :corner, do: Roki.AnimeCorner.week(params["week"])

    # A genre this kind has; none for Anime Corner's ranking, which is a fixed list.
    genre =
      with slug when is_binary(slug) <- Roki.Genres.parse(params["genre"]),
           true <-
             sort != :corner and
               Enum.any?(Roki.Genres.browse_options(socket.assigns.kind), &(elem(&1, 0) == slug)) do
        slug
      else
        _ -> nil
      end

    changed? =
      sort != socket.assigns.sort or season != socket.assigns.season or
        week != socket.assigns.week or genre != socket.assigns.genre or socket.assigns.page == 0

    socket = assign(socket, sort: sort, season: season, week: week, genre: genre, size: size)

    socket =
      if changed?,
        do:
          socket
          |> assign(items: [], page: 0, more?: false, loading?: true, error: nil)
          |> show_held(),
        else: socket

    {:noreply, if(connected?(socket) and changed?, do: fetch_first(socket), else: socket)}
  end

  # What is already held of this list (the cache, no request) is drawn at once — in the first
  # render, before the connection is even up — and what this person has watched of it is filled
  # in when it is worked out. Coming back with the back button it is every page that was loaded.
  defp show_held(%{assigns: a} = socket) do
    upto = with %{pages: pages} <- a.place, do: pages, else: (_ -> 1)
    held = for n <- 1..upto, do: Browse.peek(a.kind, a.sort, n, a.season, a.week, a.genre)

    if Enum.all?(held, &match?({:ok, _, _}, &1)) do
      {:ok, _, more?} = List.last(held)
      items = Enum.flat_map(held, fn {:ok, items, _} -> items end)
      assign(socket, items: items, page: upto, more?: more?, loading?: false)
    else
      socket
    end
  end

  # The first load. Coming back with the back button it is every page that was loaded, at once,
  # so the list appears whole and the scroll position can be restored in one step.
  defp fetch_first(%{assigns: %{place: %{pages: pages, y: y}}} = socket) do
    socket |> assign(place: nil, place_y: y) |> fetch(1, pages)
  end

  defp fetch_first(socket), do: fetch(socket, 1)

  defp fetch(socket, n, upto \\ nil) do
    %{kind: kind, sort: sort, season: season, week: week, genre: genre, uuid: uuid} =
      socket.assigns

    last = upto || n

    start_async(socket, {:page, {sort, season, week, genre}, last}, fn ->
      results =
        if last > n,
          do: RokiWeb.Place.pages(last, &Browse.page(kind, sort, &1, uuid, season, week, genre)),
          else: [Browse.page(kind, sort, n, uuid, season, week, genre)]

      case Enum.find(results, &(not match?({:ok, _, _}, &1))) do
        nil ->
          items = Enum.flat_map(results, fn {:ok, items, _more?} -> items end)
          {:ok, _, more?} = List.last(results)

          {:ok, last, Roki.Laev.annotate(uuid, items), more?, Roki.Laev.seen_keys(uuid, items),
           corner_info(kind, sort, season, week, uuid)}

        error ->
          error
      end
    end)
  end

  # Which week of the poll is shown, the weeks there are, and what could not be matched — for
  # the line over the grid and the week choice. Already computed for the page: no request.
  defp corner_info(:anime, :corner, season, week, uuid) do
    case Roki.AnimeCorner.items(uuid, season || Laev.Season.current(), week) do
      {:ok, info} -> Map.take(info, [:week, :url, :weeks, :missing])
      _ -> nil
    end
  end

  defp corner_info(_kind, _sort, _season, _week, _uuid), do: nil

  @impl true
  def handle_event("more", _params, %{assigns: %{more?: true, loading?: false}} = socket),
    do: {:noreply, socket |> assign(:loading?, true) |> fetch(socket.assigns.page + 1)}

  def handle_event("more", _params, socket), do: {:noreply, socket}

  # The grid has been scrolled to where the reader was; the position is not needed again.
  def handle_event("placed", _params, socket), do: {:noreply, assign(socket, :place_y, nil)}

  # Order and size live in the address, so a view can be linked to and the back button works.
  def handle_event("sort", %{"sort" => sort}, socket),
    do: {:noreply, push_patch(socket, to: view_path(socket, sort: Browse.sort(sort)))}

  # A genre from the menu, or none ("All genres"); the address carries it.
  def handle_event("genre", %{"genre" => genre}, socket),
    do: {:noreply, push_patch(socket, to: view_path(socket, genre: Roki.Genres.parse(genre)))}

  # Anime seasons: further back in the list, or one typed by name ("summer 2015", "2015 fall").
  def handle_event("more_seasons", _params, socket),
    do: {:noreply, update(socket, :season_count, &(&1 + 12))}

  def handle_event("season_search", %{"q" => q}, socket) do
    case parse_season(q) do
      {:season, season} ->
        {:noreply,
         socket
         |> assign(:season_error, nil)
         |> push_event("roki:hide", %{id: "season-picker-panel"})
         |> push_patch(to: view_path(socket, season: season))}

      {:year, year} ->
        # Just a year: open the list far enough back to include it, and scroll there.
        count = max(socket.assigns.season_count, season_distance(year) + 4)

        {:noreply,
         socket
         |> assign(season_count: count, season_error: nil)
         |> push_event("roki:scrollto", %{id: "s-#{year}-fall", within: "season-list"})}

      :error ->
        {:noreply, assign(socket, :season_error, "Try something like summer 2015.")}
    end
  end

  # A season picked for the ranking: that season's latest poll.
  def handle_event("corner_season", %{"season" => name, "year" => year}, socket) do
    case Browse.season(name, year) do
      nil ->
        {:noreply, socket}

      season ->
        {:noreply,
         push_patch(socket,
           to: address(socket.assigns.kind, sort: :corner, season: season, week: nil)
         )}
    end
  end

  def handle_event("size", %{"size" => size}, socket) when size in @sizes do
    {:noreply, socket |> assign(:size, size) |> push_event("roki:grid", %{size: size})}
  end

  @names %{
    "winter" => :winter,
    "spring" => :spring,
    "summer" => :summer,
    "fall" => :fall,
    "autumn" => :fall
  }

  # "summer 2015", "2015 summer", "sum 15"-style prefixes of the name, or a bare year.
  defp parse_season(q) do
    text = q |> to_string() |> String.downcase() |> String.trim()

    year =
      with [y] <- Regex.run(~r/\b((?:19|20)\d{2})\b/, text, capture: :all_but_first),
           do: String.to_integer(y)

    word = text |> String.replace(~r/[^a-z]+/, " ") |> String.trim()

    name =
      if word != "",
        do:
          Enum.find_value(@names, fn {full, atom} -> String.starts_with?(full, word) && atom end)

    cond do
      is_integer(year) and year > 2100 -> :error
      is_integer(year) and name -> {:season, {year, name}}
      is_integer(year) and word == "" -> {:year, year}
      name -> {:season, {Date.utc_today().year, name}}
      true -> :error
    end
  end

  # How many quarters back from now a year's fall is.
  defp season_distance(year) do
    {now_year, now_season} = Laev.Season.current()
    idx = Enum.find_index(Laev.Season.all(), &(&1 == now_season))
    (now_year - year) * 4 + idx + 1
  end

  defp view_path(socket, overrides) do
    %{kind: kind, sort: sort, season: season, week: week, genre: genre} = socket.assigns

    address(
      kind,
      Keyword.merge([sort: sort, season: season, week: week, genre: genre], overrides)
    )
  end

  # The address of a view: order, season and (for the Anime Corner ranking) week.
  defp address(kind, view) do
    corner? = view[:sort] == :corner

    query =
      Enum.flat_map(view, fn
        {:sort, :popular} -> []
        {:season, nil} -> []
        {:season, {year, season}} -> [season: season, year: year]
        {:week, w} when w == nil or not corner? -> []
        {:week, w} -> [week: Roki.AnimeCorner.week_param(w)]
        {:genre, g} when g == nil or corner? -> []
        other -> [other]
      end)

    base = "/#{kind}"
    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  # This year's and later quarters can have titles that are not out yet.
  defp upcoming_season?({year, _season}), do: year >= Date.utc_today().year
  defp upcoming_season?(_), do: false

  @impl true
  def handle_async(
        {:page, view, _n},
        _result,
        %{assigns: %{sort: sort, season: season, week: week, genre: genre}} = socket
      )
      when view != {sort, season, week, genre},
      do: {:noreply, socket}

  def handle_async({:page, _view, _n}, {:ok, {:ok, n, items, more?, seen, corner}}, socket) do
    # What was drawn from the cache is replaced by the same titles with this person's marks on them.
    by_key = Map.new(items, &{{&1.type, &1.id}, &1})
    shown = Enum.map(socket.assigns.items, &Map.get(by_key, {&1.type, &1.id}, &1))
    known = MapSet.new(socket.assigns.items, &{&1.type, &1.id})
    fresh = Enum.reject(items, &MapSet.member?(known, {&1.type, &1.id}))
    uuid = socket.assigns.uuid

    socket =
      assign(socket,
        items: shown ++ fresh,
        page: n,
        more?: more?,
        loading?: false,
        corner: corner,
        seen: MapSet.union(socket.assigns.seen, seen)
      )

    # What is not out yet is marked, as on Featured; the other orders only list what is out.
    socket =
      if socket.assigns.sort == :popular or upcoming_season?(socket.assigns.season),
        do: start_async(socket, {:dates, n}, fn -> Roki.Watch.upcoming(uuid, fresh) end),
        else: socket

    {:noreply, maybe_hero(socket)}
  end

  def handle_async({:page, _view, _n}, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, loading?: false, error: reason)}

  def handle_async({:page, _view, _n}, {:exit, reason}, socket),
    do: {:noreply, assign(socket, loading?: false, error: reason)}

  def handle_async({:dates, _n}, {:ok, found}, socket),
    do: {:noreply, update(socket, :upcoming, &Map.merge(&1, found))}

  def handle_async({:dates, _n}, _other, socket), do: {:noreply, socket}

  # The picture across the top: the backdrop of the first title, asked for once and kept while
  # the order or the genre changes under it.
  def handle_async(:hero, {:ok, url}, socket) when is_binary(url),
    do: {:noreply, assign(socket, :hero, url)}

  def handle_async(:hero, _other, socket), do: {:noreply, socket}

  defp maybe_hero(%{assigns: %{hero: nil, items: [first | _], uuid: uuid}} = socket) do
    start_async(socket, :hero, fn ->
      case Roki.Watch.title(first.type, first.id, uuid) do
        {:ok, t} -> t[:backdrop]
        _ -> nil
      end
    end)
  end

  defp maybe_hero(socket), do: socket

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        grid: @grids[assigns.size],
        title: @titles[assigns.kind],
        sorts: Browse.sorts(assigns.kind, assigns.season),
        now: Laev.Season.current()
      )

    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      flush
      bleed
      overlay
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@kind}"}
    >
      <%!-- The title on the left; on the right what is listed (a season for anime, the order) and
            the poster size — one row, one height. The panels open under the group. --%>
      <%!-- A picture across the top, from the first of what is listed, under the floating header. The
            picture is clipped by its own box, not the section's: the pickers' panels open past it. --%>
      <section class="relative z-20 flex min-h-[clamp(18rem,42svh,28rem)] flex-col justify-end text-white">
        <div class="absolute inset-0 -z-10 overflow-hidden bg-neutral-900">
          <img
            :if={@hero}
            src={Roki.Images.local(@hero)}
            alt=""
            class="h-full w-full object-cover opacity-80"
          />
          <div class="absolute inset-0 bg-gradient-to-r from-black/80 via-black/40 to-black/10"></div>
          <div class="absolute inset-0 bg-gradient-to-t from-black/70 via-transparent to-black/50">
          </div>
        </div>

        <div class="flex flex-col gap-5 px-4 pb-6 pt-28 sm:px-6 lg:px-12 xl:px-16">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.25em] text-white/70">
              {if @kind == :anime and @season,
                do: season_text(@season),
                else: sort_text(@sorts, @sort, @corner)}
            </p>
            <h1 class="text-5xl font-bold leading-[1.04] tracking-tight drop-shadow-lg sm:text-6xl xl:text-7xl">
              {@title}
            </h1>
          </div>

          <div class="relative flex w-full flex-wrap items-center gap-2 sm:flex-nowrap">
            <.picker
              :if={@kind == :anime}
              id="season-picker"
              label="Season"
              value={season_text(@season)}
            >
              <.season_panel season={@season} count={@season_count} now={@now} error={@season_error} />
            </.picker>

            <.picker
              :if={@kind == :anime or @season == nil}
              id="order-picker"
              label="Order"
              value={sort_text(@sorts, @sort, @corner)}
            >
              <div class="p-1">
                <button
                  :for={{key, label} <- @sorts}
                  phx-click={
                    JS.push("sort", value: %{sort: key}) |> JS.hide(to: "#order-picker-panel")
                  }
                  class={[
                    "flex w-full items-center justify-between rounded-lg px-3 py-3 text-left text-base font-medium hover:bg-base-200",
                    @sort == key && "bg-base-200 text-primary"
                  ]}
                >
                  {label}
                  <.icon :if={@sort == key} name="hero-check-micro" class="h-5 w-5" />
                </button>
              </div>
            </.picker>

            <.picker
              :if={@sort != :corner}
              id="genre-picker"
              label="Genre"
              value={if @genre, do: Roki.Genres.label(@genre), else: "All genres"}
            >
              <div class="grid grid-cols-2 gap-0.5 p-1">
                <button
                  phx-click={
                    JS.push("genre", value: %{genre: ""}) |> JS.hide(to: "#genre-picker-panel")
                  }
                  class={[
                    "col-span-2 flex w-full items-center justify-between rounded-lg px-3 py-2.5 text-left text-base font-medium hover:bg-base-200",
                    @genre == nil && "bg-base-200 text-primary"
                  ]}
                >
                  All genres <.icon :if={@genre == nil} name="hero-check-micro" class="h-5 w-5" />
                </button>
                <button
                  :for={{slug, label} <- Roki.Genres.browse_options(@kind)}
                  phx-click={
                    JS.push("genre", value: %{genre: slug}) |> JS.hide(to: "#genre-picker-panel")
                  }
                  class={[
                    "flex w-full items-center justify-between rounded-lg px-3 py-2.5 text-left text-base hover:bg-base-200",
                    @genre == slug && "bg-base-200 font-medium text-primary"
                  ]}
                >
                  {label}
                  <.icon :if={@genre == slug} name="hero-check-micro" class="h-5 w-5" />
                </button>
              </div>
            </.picker>

            <%!-- The ranking's week: any season Anime Corner has polled, any week of it. --%>
            <.picker
              :if={@kind == :anime and @sort == :corner}
              id="week-picker"
              label="Week"
              value={week_text(@corner, @season || @now)}
            >
              <.week_panel
                kind={@kind}
                season={@season || @now}
                corner={@corner}
                loading?={@loading?}
                now={@now}
              />
            </.picker>

            <div
              class="join ml-auto overflow-hidden rounded-full border border-white/25 bg-black/30 text-white backdrop-blur-md"
              role="group"
              aria-label="Grid size"
            >
              <button
                :for={{size, label} <- [{"s", "Small"}, {"m", "Medium"}, {"l", "Large"}]}
                phx-click="size"
                phx-value-size={size}
                title={"#{label} posters"}
                aria-label={"#{label} posters"}
                class={[
                  "btn btn-square btn-ghost join-item h-12 w-12 border-0 text-white hover:bg-white/15",
                  @size == size && "bg-white/25"
                ]}
              >
                <.size_icon size={size} />
              </button>
            </div>
          </div>
        </div>
      </section>

      <div class="space-y-4 px-4 pb-12 pt-6 [overflow-x:clip] sm:px-6 lg:px-12 xl:px-16">
        <%!-- Where the ranking comes from, and what of it is not on TMDB. --%>
        <p :if={@sort == :corner and @corner} class="text-sm text-base-content/70">
          Anime Corner's weekly poll, {String.downcase(Roki.AnimeCorner.week_label(@corner.week))} of {Laev.Season.label(
            @season || @now
          )}: {length(@items)} titles as people voted them.
          <span :if={@corner.missing != []}>
            Not found on TMDB: {Enum.join(@corner.missing, ", ")}.
          </span>
          <a href={@corner.url} target="_blank" rel="noopener" class="link">Open the post</a>
        </p>
        <p
          :if={
            @sort == :corner and @corner == nil and not @loading? and @error == nil and @items == []
          }
          class="alert text-sm"
        >
          Anime Corner has not posted a ranking for {Laev.Season.label(@season || @now)} yet.
        </p>

        <p :if={@error == :no_tmdb_key} class="alert text-sm">
          Log in with a connected laev account to browse — titles are looked up with your own TMDB key.
        </p>
        <p :if={@error not in [nil, :no_tmdb_key]} class="alert alert-error text-sm">
          Couldn't reach TMDB just now. Try again in a minute.
        </p>

        <%!-- The same grid as the real one, so nothing moves when the posters arrive. --%>
        <ul :if={@items == [] and @loading?} class={["grid gap-4", @grid]} aria-busy="true">
          <li :for={_ <- 1..12} class="space-y-1">
            <div class="skeleton aspect-[2/3] w-full rounded-box"></div>
            <div class="skeleton h-5 w-3/4 rounded"></div>
          </li>
        </ul>

        <%!-- The hover cards' hook is on a box around the grid: the grid has `FillGrid` already. --%>
        <div :if={@items != []} id="grid-cards" phx-hook="GridCards">
          <ul
            id="grid"
            phx-hook="FillGrid"
            data-more={to_string(@more?)}
            data-page={@page}
            data-restore-y={@place_y}
            class={["grid gap-4", @grid]}
          >
            <RokiWeb.FeaturedLive.grid_card
              :for={i <- @items}
              kind={@kind}
              item={i}
              seen={MapSet.member?(@seen, {i.type, i.id})}
              upcoming={@upcoming}
              signed_in?={@uuid != nil}
            />
          </ul>
        </div>

        <%!-- The end of the list: the next page is asked for as it comes into view. --%>
        <div
          :if={@items != [] and (@more? or @loading?)}
          id="grid-more"
          phx-hook="InfiniteScroll"
          data-event="more"
          data-active={to_string(@more? and not @loading?)}
          class="flex min-h-16 items-center justify-center pt-4"
        >
          <span :if={@loading?} class="loading loading-spinner loading-md text-base-content/50"></span>
        </div>

        <p
          :if={@items == [] and not @loading? and @error == nil and @sort != :corner}
          class="py-16 text-center text-base-content/60"
        >
          Nothing here.
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  slot :inner_block, required: true

  # A big button that says what is chosen and opens a panel under it.
  defp picker(assigns) do
    ~H"""
    <div id={@id} class="min-w-0 flex-1 basis-[7.5rem] sm:relative sm:flex-none sm:basis-auto">
      <button
        type="button"
        phx-click={JS.toggle(to: "##{@id}-panel", display: "block")}
        class="btn h-12 min-h-0 w-full justify-between gap-2 rounded-full border border-white/25 bg-black/30 px-4 text-left font-semibold text-white backdrop-blur-md hover:border-white/60 hover:bg-black/45"
        aria-haspopup="listbox"
      >
        <span class="min-w-0">
          <span class="block text-[0.6rem] font-medium uppercase leading-none tracking-wide text-white/60">
            {@label}
          </span>
          <span class="block truncate text-base leading-tight text-white">{@value}</span>
        </span>
        <.icon name="hero-chevron-down-micro" class="h-4 w-4 shrink-0 text-white/80" />
      </button>
      <div
        id={"#{@id}-panel"}
        class="absolute right-0 top-full z-40 mt-2 hidden w-80 sm:left-0 sm:right-auto max-w-[calc(100vw-2rem)] rounded-box border border-base-300 bg-base-100 text-base-content shadow-xl"
        phx-click-away={JS.hide(to: "##{@id}-panel")}
        phx-window-keydown={JS.hide(to: "##{@id}-panel")}
        phx-key="escape"
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :season, :any, default: nil
  attr :count, :integer, required: true
  attr :now, :any, required: true
  attr :error, :string, default: nil

  # Every season, newest first, as far back as you scroll; "Load more" goes further, and a search
  # box takes "summer 2015" when you know what you want.
  defp season_panel(assigns) do
    assigns = assign(assigns, :seasons, Laev.Season.recent(assigns.count))
    assigns = assign(assigns, :oldest, assigns.seasons |> List.last() |> elem(0))

    ~H"""
    <form phx-submit="season_search" class="flex gap-2 border-b border-base-300 p-2">
      <input
        type="text"
        name="q"
        placeholder="Search: summer 2015"
        autocomplete="off"
        autocapitalize="off"
        spellcheck="false"
        class="input input-bordered input-sm min-w-0 flex-1"
      />
      <button type="submit" class="btn btn-sm btn-primary">Go</button>
    </form>
    <p :if={@error} class="px-3 pt-2 text-sm text-error">{@error}</p>

    <div id="season-list" class="max-h-80 overflow-y-auto p-1">
      <.link
        patch={~p"/anime"}
        phx-click={JS.hide(to: "#season-picker-panel")}
        class={[
          "flex items-center justify-between rounded-lg px-3 py-3 text-base font-medium hover:bg-base-200",
          @season == nil && "bg-base-200 text-primary"
        ]}
      >
        All anime <.icon :if={@season == nil} name="hero-check-micro" class="h-5 w-5" />
      </.link>

      <.link
        :for={{year, name} = s <- @seasons}
        id={"s-#{year}-#{name}"}
        patch={~p"/anime?#{[season: name, year: year]}"}
        phx-click={JS.hide(to: "#season-picker-panel")}
        class={[
          "flex items-center justify-between rounded-lg px-3 py-3 text-base font-medium hover:bg-base-200",
          @season == s && "bg-base-200 text-primary"
        ]}
      >
        <span>{Laev.Season.label(s)}</span>
        <span :if={s == @now} class="badge badge-primary badge-sm">now</span>
        <.icon :if={@season == s and s != @now} name="hero-check-micro" class="h-5 w-5" />
      </.link>

      <button
        :if={@oldest > 1960}
        type="button"
        phx-click="more_seasons"
        class="mt-1 flex w-full items-center justify-center gap-2 rounded-lg px-3 py-3 text-base font-medium text-primary hover:bg-base-200"
      >
        <.icon name="hero-arrow-down-micro" class="h-5 w-5" /> Load more seasons
      </button>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :season, :any, required: true
  attr :corner, :any, default: nil
  attr :loading?, :boolean, default: false
  attr :now, :any, required: true

  # A season to choose (Anime Corner has polled every one since 2020), and the weeks posted for
  # it, the season's final ranking first once there is one.
  defp week_panel(assigns) do
    {year, name} = assigns.season
    assigns = assign(assigns, year: year, name: name, years: elem(assigns.now, 0)..2020//-1)

    ~H"""
    <form phx-change="corner_season" class="flex gap-2 border-b border-base-300 p-2">
      <select name="season" class="select select-bordered select-sm flex-1" aria-label="Season">
        <option :for={s <- Laev.Season.all()} value={s} selected={s == @name}>
          {String.capitalize(Atom.to_string(s))}
        </option>
      </select>
      <select name="year" class="select select-bordered select-sm w-28" aria-label="Year">
        <option :for={y <- @years} value={y} selected={y == @year}>{y}</option>
      </select>
    </form>
    <div class="p-2">
      <p :if={@corner == nil and @loading?} class="px-1 py-2 text-sm text-base-content/60">
        Looking for the polls…
      </p>
      <p :if={@corner == nil and not @loading?} class="px-1 py-2 text-sm text-base-content/60">
        No Anime Corner poll for {Laev.Season.label(@season)}.
      </p>
      <div :if={@corner} class="flex flex-wrap gap-1">
        <.link
          :for={w <- @corner.weeks}
          patch={address(@kind, sort: :corner, season: @season, week: w)}
          phx-click={JS.hide(to: "#week-picker-panel")}
          class={["btn btn-sm", w == @corner.week && "btn-primary"]}
        >
          {Roki.AnimeCorner.week_label(w)}
        </.link>
      </div>
    </div>
    """
  end

  defp week_text(%{week: week}, season),
    do: "#{Roki.AnimeCorner.week_label(week)} · #{Laev.Season.label(season)}"

  defp week_text(nil, season), do: Laev.Season.label(season)

  defp season_text(nil), do: "All anime"
  defp season_text(season), do: Laev.Season.label(season)

  defp sort_text(sorts, sort, _corner), do: Keyword.get(sorts, sort, "Popular")

  attr :size, :string, required: true

  defp size_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 20 20" fill="currentColor" class="h-4 w-4" aria-hidden="true">
      <%= case @size do %>
        <% "s" -> %>
          <path d="M2 2h4v4H2zM8 2h4v4H8zM14 2h4v4h-4zM2 8h4v4H2zM8 8h4v4H8zM14 8h4v4h-4zM2 14h4v4H2zM8 14h4v4H8zM14 14h4v4h-4z" />
        <% "m" -> %>
          <path d="M2 2h7v7H2zM11 2h7v7h-7zM2 11h7v7H2zM11 11h7v7h-7z" />
        <% "l" -> %>
          <path d="M2 2h16v7H2zM2 11h16v7H2z" />
      <% end %>
    </svg>
    """
  end
end
