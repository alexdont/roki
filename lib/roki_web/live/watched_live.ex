defmodule RokiWeb.WatchedLive do
  @moduledoc """
  `/:username/watched` — everything a user finished, as a grid of posters or as rows (title,
  kind, year, their rating, when), newest first or by their own ratings (`?sort=top`,
  `?kind=anime`, `?genre=horror` for one genre, `?status=progress` (or `up_to_date`, `on_hold`, `finished`) for one kind of entry, `?months=0` for one list without month headings, `?rating=9` for the titles rated 9 (`?tens=1` still means 10), `?q=` to search, `?view=rows`). Open to
  everyone, like the profile; everything is read from this server (`Roki.Profile`).

  The owner has a button that turns on *select mode* (and off again): tick any number of
  titles, then give them a watch date — a film found years after it was seen goes back where it
  belongs instead of topping the list — or take them off the list.
  """
  use RokiWeb, :live_view

  import RokiWeb.PosterComponents
  import PhoenixKitWeb.Components.Core.UserInfo, only: [user_avatar: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Profile

  @page 60

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    viewer = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)
    user = Profile.user(username)

    if user == nil do
      {:ok,
       assign(socket,
         page_title: "Watched",
         user: nil,
         username: username,
         owner?: false,
         visible?: false,
         profile: nil
       )}
    else
      profile = Profile.get(user.uuid)
      owner? = viewer == user.uuid

      socket =
        assign(socket,
          page_title: "#{user.username} · watched",
          user: user,
          username: user.username,
          uuid: user.uuid,
          owner?: owner?,
          profile: profile,
          visible?: true,
          history: nil,
          ratings: %{},
          sort: :latest,
          kind: :all,
          q: "",
          view: :grid,
          rating: nil,
          status: nil,
          genre: nil,
          genre_waits: 0,
          months?: true,
          shown: @page,
          page: @page,
          place: if(connected?(socket), do: RokiWeb.Place.from_params(socket, 60)),
          place_y: nil,
          select?: false,
          selected: MapSet.new(),
          dating?: false,
          seasons: %{},
          seasons_all: %{},
          whole_title?: true,
          date_error: nil,
          notice: nil
        )

      {:ok, if(connected?(socket), do: load(socket), else: socket)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     assign(socket,
       sort: Profile.sort(params["sort"]),
       kind: Profile.kind(params["kind"]),
       view: if(params["view"] == "rows", do: :rows, else: :grid),
       q: params["q"] |> to_string() |> String.trim() |> String.slice(0, 80),
       months?: params["months"] != "0",
       status: status_param(params["status"]),
       genre: Roki.Genres.parse(params["genre"]),
       rating: Profile.rating_param(params["rating"] || if(params["tens"] == "1", do: "10"))
     )
     |> take_place()}
  end

  # Back from a title: as many of the list's pages as were open, and the place to scroll to. Any
  # other change of the address starts at the top of the first page.
  defp take_place(%{assigns: %{place: %{pages: pages, y: y}}} = socket),
    do: assign(socket, place: nil, place_y: y, shown: pages * socket.assigns.page)

  defp take_place(socket), do: assign(socket, shown: socket.assigns.page, place_y: nil)

  defp load(socket) do
    uuid = socket.assigns.uuid

    socket
    |> start_async(:ratings, fn -> Profile.ratings(uuid) end)
    |> start_async(:history, fn -> Profile.history_all(uuid) end)
  end

  # One show selected, and laev's record says which of its seasons were watched: that is the
  # only time a season can be dated on its own. Looked up when the dialog opens rather than
  # with the page, since most of the time nobody opens it.
  defp seasons_for(%{assigns: %{selected: selected}} = socket) do
    with [key] <- MapSet.to_list(selected),
         %{} = item <- Enum.find(arranged(socket), &(&1.key == key)) do
      seasons_of(item, socket.assigns.seasons_all)
    else
      _ -> %{}
    end
  end

  defp arranged(%{assigns: a}) when is_list(a.history) do
    list =
      Profile.arrange(
        a.history,
        if(a.owner? or a.profile.show_ratings, do: a.ratings, else: %{}),
        a.kind,
        a.sort,
        a.rating
      )

    list = if a.status, do: Enum.filter(list, &(&1.status == a.status)), else: list

    list =
      if a.genre,
        do: Enum.filter(list, &Roki.Genres.match?(a.genre, &1.type, &1.genres)),
        else: list

    if a.q == "" do
      list
    else
      q = String.downcase(a.q)
      Enum.filter(list, &String.contains?(String.downcase(&1.title || ""), q))
    end
  end

  defp arranged(_socket), do: []

  @statuses [
    {"finished", "Finished"},
    {"progress", "In progress"},
    {"up_to_date", "Up to date"},
    {"on_hold", "On hold"}
  ]

  defp rating_note(:none), do: " without a rating"
  defp rating_note(nil), do: ""
  defp rating_note(n), do: " rated #{n}"

  defp filters_on(status, rating, genre), do: Enum.count([status, rating, genre], &(&1 != nil))

  defp status_param(value), do: if(value in Enum.map(@statuses, &elem(&1, 0)), do: value)

  defp status_label(status),
    do: Enum.find_value(@statuses, "Finished", fn {k, v} -> k == status && v end)

  # Only a finished title has a watch date to change or a mark to take off.
  defp status_title(item),
    do: status_label(item.status) <> if(item[:note], do: " · #{item.note}", else: "")

  defp finished?(%{status: status}), do: status == "finished"
  defp finished?(_), do: true

  # What can be picked in select mode. A finished title, because its date and its place on the
  # list can be changed — and a show that is still going if laev has episode records for it,
  # because one of its seasons can be dated even though the show is not done. That was the gap:
  # a show watched a season at a time is never finished, so it could not be touched at all.
  defp selectable?(item, seasons_all), do: finished?(item) or seasons_of(item, seasons_all) != %{}

  defp seasons_of(item, seasons_all) do
    case Roki.Profile.parse_key(item.key) do
      {type, id} -> Map.get(seasons_all, {type, id}, %{})
      _ -> %{}
    end
  end

  defp all_seasons(uuid) do
    case Roki.Laev.run(uuid, &Roki.Stats.season_episodes/0) do
      %{} = counts -> counts
      _ -> %{}
    end
  end

  defp selectable_key?(socket, key) do
    is_list(socket.assigns.history) and
      Enum.any?(
        socket.assigns.history,
        &(&1.key == key and selectable?(&1, socket.assigns.seasons_all))
      )
  end

  defp finished_key?(socket, key) do
    is_list(socket.assigns.history) and
      Enum.any?(socket.assigns.history, &(&1.key == key and finished?(&1)))
  end

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("more", _params, socket), do: {:noreply, update(socket, :shown, &(&1 + @page))}

  # The list has been scrolled to where the reader was; the place is not needed again.
  def handle_event("placed", _params, socket), do: {:noreply, assign(socket, :place_y, nil)}

  # Typing in the search box: the address carries it, so a search can be shared too.
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: address(socket.assigns, q: String.trim(q)), replace: true)}
  end

  # Select mode — the owner's.
  def handle_event("select_mode", _params, %{assigns: %{owner?: true}} = socket) do
    on? = not socket.assigns.select?

    {:noreply,
     assign(socket,
       select?: on?,
       selected: MapSet.new(),
       dating?: false,
       notice: nil,
       seasons_all: if(on?, do: all_seasons(socket.assigns.uuid), else: %{})
     )}
  end

  def handle_event(
        "select_toggle",
        %{"key" => key},
        %{assigns: %{owner?: true, select?: true}} = socket
      ) do
    sel = socket.assigns.selected

    cond do
      MapSet.member?(sel, key) -> {:noreply, assign(socket, :selected, MapSet.delete(sel, key))}
      selectable_key?(socket, key) -> {:noreply, assign(socket, :selected, MapSet.put(sel, key))}
      true -> {:noreply, socket}
    end
  end

  # Everything the filters show, not only the page on screen.
  def handle_event("select_all", _params, %{assigns: %{owner?: true, select?: true}} = socket),
    do:
      {:noreply,
       assign(socket, :selected, MapSet.new(for i <- arranged(socket), finished?(i), do: i.key))}

  def handle_event("select_none", _params, %{assigns: %{owner?: true}} = socket),
    do: {:noreply, assign(socket, selected: MapSet.new(), dating?: false)}

  def handle_event("date_open", _params, %{assigns: %{owner?: true, select?: true}} = socket) do
    if MapSet.size(socket.assigns.selected) > 0,
      do:
        {:noreply,
         assign(socket,
           dating?: true,
           date_error: nil,
           seasons: seasons_for(socket),
           whole_title?: Enum.all?(socket.assigns.selected, &finished_key?(socket, &1))
         )},
      else: {:noreply, socket}
  end

  def handle_event("date_close", _params, socket),
    do: {:noreply, assign(socket, dating?: false, date_error: nil, seasons: %{})}

  # One season of one show, rather than the whole title: its share of the show's time moves to
  # this day and the rest of the show stays where it was.
  def handle_event(
        "date_save",
        %{"date" => text, "season" => season},
        %{assigns: %{owner?: true, select?: true}} = socket
      )
      when season != "" do
    with {:ok, date} <- Date.from_iso8601(text),
         true <- Date.compare(date, Date.utc_today()) != :gt and date.year >= 1900,
         {n, ""} <- Integer.parse(season),
         [key] <- MapSet.to_list(socket.assigns.selected),
         {type, id} <- Roki.Profile.parse_key(key) do
      :ok = Profile.set_season_date(socket.assigns.uuid, type, id, n, date)

      {:noreply,
       socket
       |> assign(dating?: false, selected: MapSet.new(), date_error: nil, seasons: %{})
       |> assign(
         notice:
           "Season #{n} set to #{Calendar.strftime(date, "%B %-d, %Y")}. The rest of the show stays where it was."
       )}
    else
      _ ->
        {:noreply,
         assign(socket, :date_error, "Pick a day that has happened (not in the future).")}
    end
  end

  # The chosen day goes on every title selected, in the order the list shows them.
  def handle_event(
        "date_save",
        %{"date" => text},
        %{assigns: %{owner?: true, select?: true}} = socket
      ) do
    with {:ok, date} <- Date.from_iso8601(text),
         true <- Date.compare(date, Date.utc_today()) != :gt and date.year >= 1900 do
      keys =
        for i <- arranged(socket),
            finished?(i),
            MapSet.member?(socket.assigns.selected, i.key),
            do: i.key

      {:ok, n} = Profile.set_watched_at(socket.assigns.uuid, keys, date)

      {:noreply,
       socket
       |> assign(
         history: Profile.history_all(socket.assigns.uuid),
         dating?: false,
         selected: MapSet.new(),
         date_error: nil
       )
       |> assign(
         notice:
           "#{n} #{if n == 1, do: "title", else: "titles"} set to #{Calendar.strftime(date, "%B %-d, %Y")}."
       )}
    else
      _ ->
        {:noreply,
         assign(socket, :date_error, "Pick a day that has happened (not in the future).")}
    end
  end

  def handle_event("remove", _params, %{assigns: %{owner?: true, select?: true}} = socket) do
    keys = for k <- socket.assigns.selected, finished_key?(socket, k), do: k
    {:ok, n} = Profile.remove_watched(socket.assigns.uuid, keys)

    {:noreply,
     socket
     |> assign(
       history: Profile.history_all(socket.assigns.uuid),
       selected: MapSet.new(),
       dating?: false
     )
     |> assign(
       notice: "#{n} #{if n == 1, do: "title", else: "titles"} taken off your watched list."
     )}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── async results ──────────────────────────────────────────────────

  @impl true
  def handle_async(:history, {:ok, items}, socket) when is_list(items),
    do: {:noreply, socket |> assign(:history, items) |> wait_for_genres()}

  def handle_async(:history, _other, socket), do: {:noreply, assign(socket, :history, [])}

  def handle_async(:ratings, {:ok, ratings}, socket) when is_map(ratings),
    do: {:noreply, assign(socket, :ratings, ratings)}

  def handle_async(:ratings, _other, socket), do: {:noreply, socket}

  # Genres are read from TMDB in the background, once for each title. While some are still to come
  # the page looks again every few seconds, so a filtered list fills in by itself.
  @impl true
  def handle_info(:reread_genres, socket) do
    uuid = socket.assigns.uuid
    {:noreply, start_async(socket, :history, fn -> Profile.history_all(uuid) end)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp genres_pending(history) when is_list(history),
    do: Enum.count(history, &(&1.genres == nil and is_integer(&1.id)))

  defp genres_pending(_), do: 0

  defp wait_for_genres(%{assigns: %{history: history, genre_waits: waits}} = socket) do
    if connected?(socket) and genres_pending(history) > 0 and waits < 90 do
      Process.send_after(self(), :reread_genres, 5_000)
      assign(socket, :genre_waits, waits + 1)
    else
      socket
    end
  end

  # ── view ───────────────────────────────────────────────────────────

  # The address of a view: the assigns, with `overrides` (a new search, a new view …) laid on.
  defp address(a, overrides) do
    v =
      %{
        sort: a.sort,
        kind: a.kind,
        rating: a.rating,
        status: a.status,
        genre: a.genre,
        months: a.months?,
        q: a.q,
        view: a.view
      }
      |> Map.merge(Map.new(overrides))

    query =
      Enum.flat_map([:sort, :kind, :rating, :status, :genre, :months, :q, :view], fn
        :sort -> if v.sort == :top, do: [sort: "top"], else: []
        :kind -> if v.kind != :all, do: [kind: Atom.to_string(v.kind)], else: []
        :rating -> if v.rating, do: [rating: v.rating], else: []
        :status -> if v.status, do: [status: v.status], else: []
        :genre -> if v.genre, do: [genre: v.genre], else: []
        :months -> if v.months, do: [], else: [months: "0"]
        :q -> if v.q != "", do: [q: v.q], else: []
        :view -> if v.view == :rows, do: [view: "rows"], else: []
      end)

    base = "/#{a.username}/watched"
    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  @months ~w(January February March April May June July August September October November December)

  defp day(%{dated?: true, at: at}) do
    d = DateTime.from_unix!(at)
    "#{d.day} #{String.slice(Enum.at(@months, d.month - 1), 0, 3)} #{d.year}"
  end

  defp day(_), do: nil

  # Under a month's name, when the list is in the order things were watched.
  defp group_label(%{dated?: true, at: at}) do
    d = DateTime.from_unix!(at)
    "#{Enum.at(@months, d.month - 1)} #{d.year}"
  end

  defp group_label(_), do: "No date"

  defp groups(items, :latest, true),
    do: Enum.chunk_by(items, &group_label/1) |> Enum.map(&{group_label(hd(&1)), &1})

  defp groups(items, _sort, _months), do: [{nil, items}]

  defp kind_label(%{anime: true}), do: "Anime"
  defp kind_label(%{type: "movie"}), do: "Movie"
  defp kind_label(%{type: "tv"}), do: "Show"
  defp kind_label(_), do: "Anime"

  @impl true
  def render(assigns) do
    items = arranged(%{assigns: assigns})
    shown = Enum.take(items, assigns.shown)

    assigns =
      assign(assigns,
        items: items,
        groups: groups(shown, assigns.sort, assigns.months?),
        today: Date.utc_today() |> Date.to_iso8601()
      )

    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@username}/watched"}
    >
      <p :if={@user == nil} class="py-24 text-center text-base-content/60">
        There is no one called <strong>{@username}</strong> here.
      </p>

      <div :if={@visible?} class={["space-y-6", @select? && "pb-28"]}>
        <%!-- The header. On a phone: a slim title bar that stays at the top (Select always in
              reach), then the search with the view switch, then the kind tabs with the sort in
              a small menu. On a wide screen the same pieces become one toolbar (the wrappers
              vanish with `contents` and `order-*` lays the pieces out). --%>
        <div class="contents lg:sticky lg:top-0 lg:z-30 lg:-mx-8 lg:flex lg:flex-wrap lg:items-center lg:gap-x-5 lg:gap-y-3 lg:border-b lg:border-base-300/60 lg:bg-base-100/90 lg:px-8 lg:py-3 lg:backdrop-blur">
          <div class="sticky top-0 z-30 -mx-4 flex items-center gap-2.5 border-b border-base-300/50 bg-base-100/90 px-4 py-2 backdrop-blur sm:-mx-6 sm:px-6 lg:contents">
            <.link
              navigate={"/#{@username}"}
              class="flex min-w-0 shrink-0 items-center gap-2 text-base-content/70 hover:text-base-content lg:order-1"
            >
              <span class="lg:hidden"><.user_avatar user={@user} size="sm" /></span>
              <span class="hidden lg:block"><.user_avatar user={@user} size="md" /></span>
              <span class="hidden truncate font-semibold lg:inline">{@user.username}</span>
            </.link>
            <h1 class="text-xl font-bold sm:text-2xl lg:order-2 lg:text-3xl">Watched</h1>
            <span
              :if={is_list(@history)}
              class="rounded-full bg-base-200 px-2 py-0.5 text-xs font-medium tabular-nums text-base-content/60 lg:order-3 lg:bg-transparent lg:px-0 lg:text-sm"
            >{length(@items)}</span>

            <%!-- Select mode, for the owner: one button, on and off. --%>
            <button
              :if={@owner?}
              type="button"
              phx-click="select_mode"
              aria-pressed={to_string(@select?)}
              class={[
                "btn btn-sm ml-auto gap-1.5 rounded-full lg:order-7 lg:btn-md",
                @select? && "btn-primary"
              ]}
            >
              <.icon name={if @select?, do: "hero-check", else: "hero-check-circle"} class="h-4 w-4" />
              {if @select?, do: "Done", else: "Select"}
            </button>
          </div>

          <%!-- The search, and beside it how the list is laid out: posters or rows. --%>
          <div class="flex items-center gap-2 pb-3 pt-3 lg:contents lg:py-0">
            <form
              id="watched-search"
              phx-change="search"
              phx-submit="search"
              class="min-w-0 flex-1 sm:max-w-md lg:order-4 lg:w-96 lg:flex-none"
            >
              <label class="flex h-10 w-full items-center gap-2 rounded-full bg-base-200 px-3.5 focus-within:ring-2 focus-within:ring-primary/60 lg:h-12 lg:border lg:border-base-300 lg:bg-base-100">
                <.icon name="hero-magnifying-glass" class="h-4 w-4 shrink-0 text-base-content/50" />
                <input
                  type="text"
                  name="q"
                  value={@q}
                  placeholder="Search what you watched…"
                  autocomplete="off"
                  phx-debounce="300"
                  class="min-w-0 grow bg-transparent text-sm outline-none placeholder:text-base-content/45"
                />
              </label>
            </form>
            <div
              class="inline-flex shrink-0 overflow-hidden rounded-full bg-base-200 p-0.5 lg:order-6 lg:h-12 lg:items-center"
              role="group"
              aria-label="View"
            >
              <.link
                patch={address(assigns, view: :grid)}
                class={[
                  "flex h-9 w-9 items-center justify-center rounded-full transition lg:h-10 lg:w-10",
                  @view == :grid && "bg-base-100 shadow-sm"
                ]}
                aria-label="Grid view"
                title="Grid"
              >
                <.icon name="hero-squares-2x2" class="h-5 w-5" />
              </.link>
              <.link
                patch={address(assigns, view: :rows)}
                class={[
                  "flex h-9 w-9 items-center justify-center rounded-full transition lg:h-10 lg:w-10",
                  @view == :rows && "bg-base-100 shadow-sm"
                ]}
                aria-label="List view"
                title="List"
              >
                <.icon name="hero-bars-3" class="h-5 w-5" />
              </.link>
            </div>
          </div>

          <%!-- The kinds as tabs, and the sort: a menu on a phone, plain buttons on a wide screen. --%>
          <div class="flex items-center gap-3 pb-4 lg:order-8 lg:basis-full lg:gap-4 lg:pb-0">
            <div class="grid min-w-0 flex-1 grid-cols-4 rounded-full bg-base-200 p-0.5 lg:flex lg:flex-none lg:bg-transparent lg:p-0 lg:gap-1.5">
              <.link
                :for={{k, label} <- Profile.kinds()}
                patch={address(assigns, kind: k)}
                class={[
                  "flex h-8 items-center justify-center whitespace-nowrap rounded-full px-2 text-sm font-medium transition lg:h-9 lg:px-4",
                  @kind == k &&
                    "bg-base-100 text-primary shadow-sm lg:bg-primary lg:text-primary-content",
                  @kind != k && "text-base-content/70 hover:text-base-content lg:bg-base-200"
                ]}
              >
                {label}
              </.link>
            </div>

            <%!-- Phone: sort and rating in one menu. --%>
            <div class="dropdown dropdown-end shrink-0 lg:hidden">
              <div
                tabindex="0"
                role="button"
                class="btn btn-sm h-9 gap-1 rounded-full border-0 bg-base-200 px-3 font-medium"
                aria-label="Sort and filter"
              >
                <.icon name="hero-adjustments-horizontal" class="h-4 w-4" />
                {if @sort == :top, do: "Rating", else: "Latest"}
                <span
                  :if={filters_on(@status, @rating, @genre) > 0}
                  class="badge badge-primary badge-xs"
                >{filters_on(@status, @rating, @genre)}</span>
              </div>
              <div
                tabindex="0"
                class="dropdown-content z-40 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
              >
                <p class="px-1 pb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/50">
                  Sort
                </p>
                <div class="grid grid-cols-2 gap-1.5">
                  <.link
                    :for={{s, label} <- [{:latest, "Latest"}, {:top, "By rating"}]}
                    patch={address(assigns, sort: s)}
                    onclick="document.activeElement.blur()"
                    class={[
                      "btn btn-sm rounded-full border-0",
                      @sort == s && "btn-primary",
                      @sort != s && "bg-base-200"
                    ]}
                  >{label}</.link>
                </div>
                <.months_toggle a={assigns} class="mt-3" />
                <.status_picker a={assigns} />
                <.genre_picker a={assigns} />
                <.rating_picker :if={@owner? or @profile.show_ratings} a={assigns} />
              </div>
            </div>

            <%!-- Wide screen: sort as pills, rating as a menu. --%>
            <div class="hidden items-center gap-1.5 lg:flex">
              <.link
                :for={{s, label} <- [{:latest, "Latest"}, {:top, "By rating"}]}
                patch={address(assigns, sort: s)}
                class={[
                  "btn btn-sm h-9 rounded-full border-0 text-sm font-medium",
                  @sort == s && "btn-primary",
                  @sort != s && "bg-base-200"
                ]}
              >
                {label}
              </.link>
              <.months_toggle a={assigns} pill />
              <div class="dropdown">
                <div
                  tabindex="0"
                  role="button"
                  class={[
                    "btn btn-sm h-9 gap-1 rounded-full border-0 text-sm font-medium",
                    @genre && "btn-primary",
                    !@genre && "bg-base-200"
                  ]}
                >
                  {if @genre, do: Roki.Genres.label(@genre), else: "Genre"}
                  <.icon name="hero-chevron-down-micro" class="h-4 w-4" />
                </div>
                <div
                  tabindex="0"
                  class="dropdown-content z-40 mt-2 w-72 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
                >
                  <.genre_picker a={assigns} heading={false} />
                </div>
              </div>
              <div class="dropdown">
                <div
                  tabindex="0"
                  role="button"
                  class={[
                    "btn btn-sm h-9 gap-1 rounded-full border-0 text-sm font-medium",
                    @status && "btn-primary",
                    !@status && "bg-base-200"
                  ]}
                >
                  {if @status, do: status_label(@status), else: "Status"}
                  <.icon name="hero-chevron-down-micro" class="h-4 w-4" />
                </div>
                <div
                  tabindex="0"
                  class="dropdown-content z-40 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
                >
                  <.status_picker a={assigns} heading={false} />
                </div>
              </div>
              <div :if={@owner? or @profile.show_ratings} class="dropdown">
                <div
                  tabindex="0"
                  role="button"
                  class={[
                    "btn btn-sm h-9 gap-1 rounded-full border-0 text-sm font-medium",
                    @rating && "btn-primary",
                    !@rating && "bg-base-200"
                  ]}
                >
                  {cond do
                    @rating == :none -> "Not rated"
                    @rating -> "★ #{@rating}"
                    true -> "★ Rating"
                  end}
                  <.icon name="hero-chevron-down-micro" class="h-4 w-4" />
                </div>
                <div
                  tabindex="0"
                  class="dropdown-content z-40 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
                >
                  <.rating_picker a={assigns} heading={false} />
                </div>
              </div>
            </div>
          </div>
        </div>

        <p :if={@notice} class="rounded-box bg-success/10 px-4 py-3 text-sm text-success">
          {@notice}
        </p>
        <p :if={@genre && genres_pending(@history) > 0} class="text-sm text-base-content/60">
          Still reading the genres of {genres_pending(@history)} titles. They join the list as they arrive.
        </p>

        <ul
          :if={@history == nil}
          class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8"
          aria-busy="true"
        >
          <li :for={_ <- 1..8} class="space-y-1">
            <div class="skeleton aspect-[2/3] w-full rounded-box"></div>
            <div class="skeleton h-4 w-3/4 rounded"></div>
          </li>
        </ul>

        <p :if={@history == []} class="text-sm text-base-content/50">
          {if @owner?,
            do: "Nothing finished yet. What you watch to the end shows up here.",
            else: "Nothing here yet."}
        </p>
        <p
          :if={@history != nil and @history != [] and @items == []}
          class="text-sm text-base-content/50"
        >
          {if @q != "",
            do: "Nothing watched matches \"#{@q}\".",
            else: "Nothing of that kind#{rating_note(@rating)}."}
        </p>

        <div
          :if={is_list(@history)}
          id="watched-list"
          phx-hook="KeepPlace"
          data-page={div(@shown + @page - 1, @page)}
          data-restore-y={@place_y}
          class="space-y-6"
        >
          <div :for={{label, group} <- @groups} class="space-y-3">
            <h2 :if={label} class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              {label}
            </h2>

            <%!-- Grid: the posters, a tick in the corner while selecting. --%>
            <ul
              :if={@view == :grid}
              class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8"
            >
              <li :for={i <- group} class="space-y-1">
                <%!-- The same poster in both modes, so turning select mode on changes nothing's size
                    (and the page does not move): while selecting, a clear button lies over it and
                    the ring and the tick are drawn on top. --%>
                <div class="relative">
                  <.poster
                    item={Map.put(i, :badge, nil)}
                    cached_titles={@cached_titles}
                    compact
                    title?={false}
                  />
                  <.status_pill item={i} />
                  <button
                    :if={@select? and selectable?(i, @seasons_all)}
                    type="button"
                    phx-click="select_toggle"
                    phx-value-key={i.key}
                    aria-pressed={to_string(MapSet.member?(@selected, i.key))}
                    aria-label={"Select #{i.title}"}
                    class="absolute inset-0 z-10 cursor-pointer"
                  ></button>
                  <div
                    :if={@select? and selectable?(i, @seasons_all)}
                    class={[
                      "pointer-events-none absolute inset-x-0 top-0 z-20 aspect-[2/3] rounded-box transition",
                      MapSet.member?(@selected, i.key) && "ring-4 ring-primary"
                    ]}
                  >
                    <.tick selected={MapSet.member?(@selected, i.key)} />
                  </div>
                </div>
                <div class="flex items-center justify-between text-xs text-base-content/50">
                  <span>{day(i)}</span>
                  <span
                    :if={i.score != nil and (@owner? or @profile.show_ratings)}
                    class="font-semibold text-warning"
                  >★ {Profile.score_text(i.score)}</span>
                </div>
              </li>
            </ul>

            <%!-- Rows: one to a line, with what you would want to know. --%>
            <ul
              :if={@view == :rows}
              class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300"
            >
              <li :for={i <- group}>
                <.row
                  item={i}
                  select?={@select?}
                  selectable?={selectable?(i, @seasons_all)}
                  selected={MapSet.member?(@selected, i.key)}
                  show_score={@owner? or @profile.show_ratings}
                />
              </li>
            </ul>
          </div>
        </div>

        <%!-- The end of the list: the next sixty are shown as it comes into view. --%>
        <div
          :if={length(@items) > @shown}
          id="watched-more"
          phx-hook="InfiniteScroll"
          data-event="more"
          data-active="true"
          class="flex min-h-16 items-center justify-center"
        >
          <span class="loading loading-spinner loading-md text-base-content/50"></span>
        </div>
      </div>

      <%!-- Select mode's bar: how many and which, then what to do with them. Two lines on a
            phone, one on a wide screen. --%>
      <div
        :if={@select?}
        class="fixed inset-x-0 bottom-0 z-40 border-t border-base-300 bg-base-100/95 px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-3 shadow-[0_-8px_24px_-12px_rgba(0,0,0,0.3)] backdrop-blur"
      >
        <div class="mx-auto max-w-6xl space-y-3 sm:flex sm:items-center sm:gap-4 sm:space-y-0">
          <div class="flex items-center gap-1 sm:flex-1">
            <p class="min-w-0 flex-1 text-sm"><b>{MapSet.size(@selected)}</b> selected</p>
            <button
              type="button"
              phx-click="select_all"
              class="btn btn-ghost btn-sm whitespace-nowrap"
            >All {length(@items)}</button>
            <button
              type="button"
              phx-click="select_none"
              class="btn btn-ghost btn-sm"
              disabled={MapSet.size(@selected) == 0}
            >None</button>
          </div>
          <div class="grid grid-cols-2 gap-2 sm:flex">
            <button
              type="button"
              phx-click="date_open"
              class="btn btn-primary whitespace-nowrap"
              disabled={MapSet.size(@selected) == 0}
            >
              <.icon name="hero-calendar-days" class="h-4 w-4" /> Edit watch date
            </button>
            <button
              type="button"
              phx-click="remove"
              data-confirm={"Take #{MapSet.size(@selected)} off your watched list? Their ratings stay."}
              class="btn btn-error btn-outline"
              disabled={MapSet.size(@selected) == 0}
            >
              <.icon name="hero-trash" class="h-4 w-4" /> Remove
            </button>
          </div>
        </div>
      </div>

      <%!-- The date editor: one day for everything selected. --%>
      <div
        :if={@owner? and @dating?}
        class="fixed inset-0 z-50 flex items-end justify-center sm:items-center"
        role="dialog"
        aria-modal="true"
        aria-label="Edit watch date"
      >
        <div class="absolute inset-0 bg-black/60" phx-click="date_close"></div>
        <form
          id="date-form"
          phx-submit="date_save"
          class="relative w-full max-w-md space-y-4 rounded-t-box bg-base-100 p-5 pb-[max(1.25rem,env(safe-area-inset-bottom))] shadow-2xl sm:rounded-box"
        >
          <div>
            <h2 class="text-lg font-semibold">
              When did you watch {if MapSet.size(@selected) == 1, do: "it", else: "them"}?
            </h2>
            <p :if={@whole_title?} class="text-sm text-base-content/60">
              {MapSet.size(@selected)} {if MapSet.size(@selected) == 1, do: "title", else: "titles"} will be put on this day in your history — anywhere back, years if you like. They keep the order they have now.
            </p>
            <p :if={!@whole_title?} class="text-sm text-base-content/60">
              This one is still going, so the show itself has no date to change. A season of it
              does: pick the season you watched and the day you watched it, and its share of the
              hours moves there.
            </p>
          </div>
          <input
            type="date"
            name="date"
            value={@today}
            required
            min="1900-01-01"
            max={@today}
            class="input input-bordered w-full"
            autofocus
          />
          <%!-- A show whose seasons were watched years apart: date one of them without moving
                the rest. Only offered for a single show laev has episode records for. --%>
          <label :if={@seasons != %{}} class="block space-y-1">
            <span class="text-sm font-medium">Apply to</span>
            <select name="season" class="select select-bordered w-full" required={!@whole_title?}>
              <option :if={@whole_title?} value="">The whole title</option>
              <option :if={!@whole_title?} value="" disabled selected>Pick a season</option>
              <option :for={{season, episodes} <- Enum.sort(@seasons)} value={season}>
                Season {season} only · {episodes} {if episodes == 1,
                  do: "episode",
                  else: "episodes"}
              </option>
            </select>
            <span class="block text-xs text-base-content/60">
              A season takes its share of the show's hours with it, counted by episodes watched.
            </span>
          </label>
          <p :if={@date_error} class="text-sm text-error">{@date_error}</p>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="date_close" class="btn btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end

  attr :selected, :boolean, default: false

  # The round tick in a selectable poster's corner.
  # Month headings on or off. They only apply to the newest-first order, so the switch is
  # shown but idle (and says why) when the list is sorted by rating.
  attr :a, :map, required: true
  attr :class, :string, default: ""
  attr :pill, :boolean, default: false

  defp months_toggle(assigns) do
    ~H"""
    <.link
      patch={address(@a, months: not @a.months?)}
      onclick={if @pill, do: "document.activeElement.blur()", else: nil}
      role="switch"
      aria-checked={to_string(@a.months?)}
      class={[
        @pill && "btn btn-sm h-9 gap-1.5 rounded-full border-0 text-sm font-medium",
        @pill && @a.months? && "btn-primary",
        @pill && !@a.months? && "bg-base-200",
        !@pill &&
          "flex items-center justify-between rounded-xl bg-base-200 px-3 py-2 text-sm font-medium",
        @a.sort != :latest && "opacity-50",
        @class
      ]}
      title={if @a.sort != :latest, do: "Month headings show when sorted by latest"}
    >
      <span class="flex items-center gap-1.5">
        <.icon name="hero-calendar-days" class="h-4 w-4" /> By month
      </span>
      <input
        :if={!@pill}
        type="checkbox"
        class="toggle toggle-primary toggle-sm pointer-events-none"
        checked={@a.months?}
        tabindex="-1"
        aria-hidden="true"
      />
    </.link>
    """
  end

  # Which genre: every one, or one of those the kind on show has (films and shows do not share them all).
  attr :a, :map, required: true
  attr :heading, :boolean, default: true

  defp genre_picker(assigns) do
    options =
      case assigns.a.kind do
        :movie -> Roki.Genres.options(:movies)
        :all -> Roki.Genres.all()
        _ -> Roki.Genres.options(:shows)
      end

    assigns = assign(assigns, :options, options)

    ~H"""
    <div>
      <p
        :if={@heading}
        class="px-1 pb-1.5 pt-3 text-xs font-semibold uppercase tracking-wide text-base-content/50"
      >
        Genre
      </p>
      <div class="grid grid-cols-3 gap-1.5">
        <.link
          patch={address(@a, genre: nil)}
          onclick="document.activeElement.blur()"
          class={[
            "btn btn-sm rounded-full border-0 px-1",
            @a.genre == nil && "btn-primary",
            @a.genre != nil && "bg-base-200"
          ]}
        >
          All
        </.link>
        <.link
          :for={{slug, label} <- @options}
          patch={address(@a, genre: slug)}
          onclick="document.activeElement.blur()"
          class={[
            "btn btn-sm rounded-full border-0 px-1 text-xs",
            @a.genre == slug && "btn-primary",
            @a.genre != slug && "bg-base-200"
          ]}
        >
          {label}
        </.link>
      </div>
    </div>
    """
  end

  # Which entries: everything, or only what was finished / is in progress / is up to date / is on hold.
  attr :a, :map, required: true
  attr :heading, :boolean, default: true

  defp status_picker(assigns) do
    assigns = assign(assigns, :statuses, @statuses)

    ~H"""
    <div>
      <p
        :if={@heading}
        class="px-1 pb-1.5 pt-3 text-xs font-semibold uppercase tracking-wide text-base-content/50"
      >
        Show
      </p>
      <div class="grid grid-cols-2 gap-1.5">
        <.link
          patch={address(@a, status: nil)}
          onclick="document.activeElement.blur()"
          class={[
            "btn btn-sm rounded-full border-0",
            @a.status == nil && "btn-primary",
            @a.status != nil && "bg-base-200"
          ]}
        >
          All
        </.link>
        <.link
          :for={{key, label} <- @statuses}
          patch={address(@a, status: key)}
          onclick="document.activeElement.blur()"
          class={[
            "btn btn-sm rounded-full border-0 whitespace-nowrap",
            @a.status == key && "btn-primary",
            @a.status != key && "bg-base-200"
          ]}
        >
          {label}
        </.link>
      </div>
    </div>
    """
  end

  # The small marker on a title that is not finished: where it stands, and laev's progress line.
  attr :item, :map, required: true

  defp status_pill(assigns) do
    ~H"""
    <span
      :if={!finished?(@item)}
      title={status_title(@item)}
      class="pointer-events-none absolute left-1.5 top-1.5 z-10 inline-flex items-center gap-1 rounded-full bg-black/70 px-1.5 py-1 text-[0.6rem] font-semibold leading-none text-white shadow backdrop-blur-sm"
    >
      <span class={[
        "h-1.5 w-1.5 rounded-full",
        @item.status == "progress" && "bg-warning",
        @item.status == "up_to_date" && "bg-success",
        @item.status == "on_hold" && "bg-base-content/50"
      ]}></span>
      {status_label(@item.status)}
    </span>
    """
  end

  # "Rated": any, or one whole rating, 10 down to 1. A tap on the one already chosen lets it go.
  attr :a, :map, required: true
  attr :heading, :boolean, default: true

  defp rating_picker(assigns) do
    ~H"""
    <div>
      <p
        :if={@heading}
        class="px-1 pb-1.5 pt-3 text-xs font-semibold uppercase tracking-wide text-base-content/50"
      >
        Rated
      </p>
      <div class="grid grid-cols-5 gap-1.5">
        <.link
          :for={n <- 10..1//-1}
          patch={address(@a, rating: if(@a.rating == n, do: nil, else: n))}
          onclick="document.activeElement.blur()"
          aria-label={"Rated #{n}"}
          class={[
            "btn btn-sm rounded-full border-0 px-0 tabular-nums",
            @a.rating == n && "btn-primary",
            @a.rating != n && "bg-base-200"
          ]}
        >
          {n}
        </.link>
      </div>
      <.link
        patch={address(@a, rating: if(@a.rating == :none, do: nil, else: :none))}
        onclick="document.activeElement.blur()"
        class={[
          "btn btn-sm mt-1.5 w-full rounded-full border-0",
          @a.rating == :none && "btn-primary",
          @a.rating != :none && "bg-base-200"
        ]}
      >
        Not rated yet
      </.link>
      <.link
        :if={@a.rating}
        patch={address(@a, rating: nil)}
        onclick="document.activeElement.blur()"
        class="mt-2 block rounded-full py-1.5 text-center text-sm text-base-content/60 hover:bg-base-200"
      >
        Any rating
      </.link>
    </div>
    """
  end

  defp tick(assigns) do
    ~H"""
    <span class={[
      "absolute right-1.5 top-1.5 flex h-6 w-6 items-center justify-center rounded-full border-2 shadow",
      if(@selected,
        do: "border-primary bg-primary text-primary-content",
        else: "border-white bg-black/30 text-transparent"
      )
    ]}>
      <.icon name="hero-check-micro" class="h-4 w-4" />
    </span>
    """
  end

  attr :item, :map, required: true
  attr :select?, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :selectable?, :boolean, default: true
  attr :show_score, :boolean, default: true

  # One title as a line: a small poster, its name, what kind and which year, and on the right
  # the owner's rating and the day.
  defp row(assigns) do
    assigns = assign(assigns, href: href(assigns.item))

    ~H"""
    <%= if @select? and @selectable? do %>
      <button
        type="button"
        phx-click="select_toggle"
        phx-value-key={@item.key}
        aria-pressed={to_string(@selected)}
        class={[
          "flex w-full items-center gap-3 p-2 text-left transition hover:bg-base-200 sm:p-3",
          @selected && "bg-primary/10"
        ]}
      >
        <.row_body item={@item} show_score={@show_score} />
        <span class={[
          "flex h-6 w-6 shrink-0 items-center justify-center rounded-full border-2",
          if(@selected,
            do: "border-primary bg-primary text-primary-content",
            else: "border-base-content/30 text-transparent"
          )
        ]}>
          <.icon name="hero-check-micro" class="h-4 w-4" />
        </span>
      </button>
    <% else %>
      <.link navigate={@href} class="flex items-center gap-3 p-2 transition hover:bg-base-200 sm:p-3">
        <.row_body item={@item} show_score={@show_score} />
      </.link>
    <% end %>
    """
  end

  attr :item, :map, required: true
  attr :show_score, :boolean, default: true

  defp row_body(assigns) do
    ~H"""
    <div class="h-[4.5rem] w-12 shrink-0 overflow-hidden rounded bg-base-300 sm:h-24 sm:w-16">
      <img
        :if={@item.poster}
        src={Roki.Images.local(@item.poster)}
        alt=""
        loading="lazy"
        class="h-full w-full object-cover"
        draggable="false"
      />
    </div>
    <div class="min-w-0 flex-1">
      <div class="truncate font-medium">{@item.title}</div>
      <div class="truncate text-sm text-base-content/60">
        {kind_label(@item)}<span :if={@item.year}> · {@item.year}</span>
      </div>
      <div :if={!finished?(@item)} class="flex items-center gap-1.5 text-xs text-base-content/70">
        <span class={[
          "h-1.5 w-1.5 rounded-full",
          @item.status == "progress" && "bg-warning",
          @item.status == "up_to_date" && "bg-success",
          @item.status == "on_hold" && "bg-base-content/50"
        ]}></span>
        <span class="font-medium">{status_label(@item.status)}</span><span
          :if={@item[:note]}
          class="truncate text-base-content/50"
        > · {@item.note}</span>
      </div>
      <div class="text-xs text-base-content/50 sm:hidden">{day(@item)}</div>
    </div>
    <div class="shrink-0 text-right">
      <div :if={@item.score != nil and @show_score} class="font-semibold text-warning">
        ★ {Profile.score_text(@item.score)}
      </div>
      <div :if={@item.score == nil and @show_score} class="text-sm text-base-content/30">
        not rated
      </div>
      <div class="hidden text-sm text-base-content/60 sm:block">{day(@item) || "No date"}</div>
    </div>
    """
  end
end
