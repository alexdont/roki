defmodule RokiWeb.CategoryLive do
  @moduledoc """
  `/movies`, `/shows`, `/anime` — one kind of title on a page of its own, in a grid with
  larger posters. Popular (what Featured shows) by default, or newest, oldest, top rated;
  the grid size is a choice at the top right, remembered in the browser. "Load more" adds a
  page at the bottom — the Featured page stays short because this is where "more" lives.
  """
  use RokiWeb, :live_view

  import RokiWeb.PosterComponents

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
       season_count: 12,
       season_error: nil,
       place: RokiWeb.Place.from_params(socket),
       place_y: nil,
       size: stored_size(socket),
       items: [],
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

    changed? =
      sort != socket.assigns.sort or season != socket.assigns.season or socket.assigns.page == 0

    socket = assign(socket, sort: sort, season: season, size: size)

    {:noreply,
     if(connected?(socket) and changed?,
       do:
         socket
         |> assign(items: [], page: 0, more?: false, loading?: true, error: nil)
         |> fetch_first(),
       else: socket
     )}
  end

  # The first load. Coming back with the back button it is every page that was loaded, at once,
  # so the list appears whole and the scroll position can be restored in one step.
  defp fetch_first(%{assigns: %{place: %{pages: pages, y: y}}} = socket) do
    socket |> assign(place: nil, place_y: y) |> fetch(1, pages)
  end

  defp fetch_first(socket), do: fetch(socket, 1)

  defp fetch(socket, n, upto \\ nil) do
    %{kind: kind, sort: sort, season: season, uuid: uuid} = socket.assigns
    last = upto || n

    start_async(socket, {:page, {sort, season}, last}, fn ->
      results =
        if last > n,
          do: RokiWeb.Place.pages(last, &Browse.page(kind, sort, &1, uuid, season)),
          else: [Browse.page(kind, sort, n, uuid, season)]

      case Enum.find(results, &(not match?({:ok, _, _}, &1))) do
        nil ->
          items = Enum.flat_map(results, fn {:ok, items, _more?} -> items end)
          {:ok, _, more?} = List.last(results)
          {:ok, last, Roki.Laev.annotate(uuid, items), more?, Roki.Laev.seen_keys(uuid, items)}

        error ->
          error
      end
    end)
  end

  @impl true
  def handle_event("more", _params, %{assigns: %{more?: true, loading?: false}} = socket),
    do: {:noreply, socket |> assign(:loading?, true) |> fetch(socket.assigns.page + 1)}

  def handle_event("more", _params, socket), do: {:noreply, socket}

  # The grid has been scrolled to where the reader was; the position is not needed again.
  def handle_event("placed", _params, socket), do: {:noreply, assign(socket, :place_y, nil)}

  # Order and size live in the address, so a view can be linked to and the back button works.
  def handle_event("sort", %{"sort" => sort}, socket),
    do: {:noreply, push_patch(socket, to: view_path(socket, sort: Browse.sort(sort)))}

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
    query =
      [sort: socket.assigns.sort, season: socket.assigns.season]
      |> Keyword.merge(overrides)
      |> Enum.flat_map(fn
        {:sort, :popular} -> []
        {:season, nil} -> []
        {:season, {year, season}} -> [season: season, year: year]
        other -> [other]
      end)

    base = "/#{socket.assigns.kind}"
    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  # This year's and later quarters can have titles that are not out yet.
  defp upcoming_season?({year, _season}), do: year >= Date.utc_today().year
  defp upcoming_season?(_), do: false

  @impl true
  def handle_async({:page, view, _n}, _result, %{assigns: %{sort: sort, season: season}} = socket)
      when view != {sort, season},
      do: {:noreply, socket}

  def handle_async({:page, _view, _n}, {:ok, {:ok, n, items, more?, seen}}, socket) do
    known = MapSet.new(socket.assigns.items, & &1.id)
    fresh = Enum.reject(items, &MapSet.member?(known, &1.id))
    uuid = socket.assigns.uuid

    socket =
      assign(socket,
        items: socket.assigns.items ++ fresh,
        page: n,
        more?: more?,
        loading?: false,
        seen: MapSet.union(socket.assigns.seen, seen)
      )

    # What is not out yet is marked, as on Featured; the other orders only list what is out.
    socket =
      if socket.assigns.sort == :popular or upcoming_season?(socket.assigns.season),
        do: start_async(socket, {:dates, n}, fn -> Roki.Watch.upcoming(uuid, fresh) end),
        else: socket

    {:noreply, socket}
  end

  def handle_async({:page, _view, _n}, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, loading?: false, error: reason)}

  def handle_async({:page, _view, _n}, {:exit, reason}, socket),
    do: {:noreply, assign(socket, loading?: false, error: reason)}

  def handle_async({:dates, _n}, {:ok, found}, socket),
    do: {:noreply, update(socket, :upcoming, &Map.merge(&1, found))}

  def handle_async({:dates, _n}, _other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        grid: @grids[assigns.size],
        title: @titles[assigns.kind],
        sorts: Browse.sorts(),
        now: Laev.Season.current()
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@kind}"}
    >
      <%!-- The title on the left; on the right what is listed (a season for anime, the order) and
            the poster size — one row, one height. The panels open under the group. --%>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
        <h1 class="min-w-[6rem] flex-1 text-2xl font-bold tracking-tight sm:text-3xl">{@title}</h1>

        <div class="relative ml-auto flex items-center gap-2">
          <.picker
            :if={@kind == :anime}
            id="season-picker"
            label="Season"
            value={season_text(@season)}
          >
            <.season_panel season={@season} count={@season_count} now={@now} error={@season_error} />
          </.picker>

          <.picker
            :if={@season == nil}
            id="order-picker"
            label="Order"
            value={sort_text(@sorts, @sort)}
          >
            <div class="p-1">
              <button
                :for={{key, label} <- @sorts}
                phx-click={JS.push("sort", value: %{sort: key}) |> JS.hide(to: "#order-picker-panel")}
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

          <div class="join" role="group" aria-label="Grid size">
            <button
              :for={{size, label} <- [{"s", "Small"}, {"m", "Medium"}, {"l", "Large"}]}
              phx-click="size"
              phx-value-size={size}
              title={"#{label} posters"}
              aria-label={"#{label} posters"}
              class={["btn btn-square join-item h-12 w-12", @size == size && "btn-active"]}
            >
              <.size_icon size={size} />
            </button>
          </div>
        </div>
      </div>

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

      <ul
        :if={@items != []}
        id="grid"
        phx-hook="FillGrid"
        data-more={to_string(@more?)}
        data-page={@page}
        data-restore-y={@place_y}
        class={["grid gap-4", @grid]}
      >
        <li :for={i <- @items} class="space-y-1">
          <.poster
            item={i}
            seen={MapSet.member?(@seen, {i.type, i.id})}
            cached_titles={@cached_titles}
            upcoming={@upcoming}
            compact
          />
        </li>
      </ul>

      <div :if={@items != [] and (@more? or @loading?)} class="flex justify-center pt-4">
        <button phx-click="more" class="btn btn-wide" disabled={@loading?}>
          <span :if={@loading?} class="loading loading-spinner loading-sm"></span> Load more
        </button>
      </div>

      <p
        :if={@items == [] and not @loading? and @error == nil}
        class="py-16 text-center text-base-content/60"
      >
        Nothing here.
      </p>
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
    <div id={@id} class="min-w-0">
      <button
        type="button"
        phx-click={JS.toggle(to: "##{@id}-panel", display: "block")}
        class="btn h-12 min-h-0 w-full justify-between gap-2 border-2 border-primary/40 bg-base-100 px-3 text-left font-semibold hover:border-primary"
        aria-haspopup="listbox"
      >
        <span class="min-w-0">
          <span class="block text-[0.6rem] font-medium uppercase leading-none tracking-wide text-base-content/50">
            {@label}
          </span>
          <span class="block truncate text-base leading-tight text-primary">{@value}</span>
        </span>
        <.icon name="hero-chevron-down-micro" class="h-4 w-4 shrink-0 text-primary" />
      </button>
      <div
        id={"#{@id}-panel"}
        class="absolute right-0 top-full z-40 mt-1 hidden w-80 max-w-[calc(100vw-2rem)] rounded-box border border-base-300 bg-base-100 shadow-xl"
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

  defp season_text(nil), do: "All anime"
  defp season_text(season), do: Laev.Season.label(season)

  defp sort_text(sorts, sort), do: Keyword.get(sorts, sort, "Popular")

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
