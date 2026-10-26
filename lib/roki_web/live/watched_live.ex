defmodule RokiWeb.WatchedLive do
  @moduledoc """
  `/:username/watched` — everything a user finished, as a grid of posters or as rows (title,
  kind, year, their rating, when), newest first or by their own ratings (`?sort=top`,
  `?kind=anime`, `?tens=1` for the ten-out-of-tens, `?q=` to search, `?view=rows`). Open to
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
      {:ok, assign(socket, page_title: "Watched", user: nil, username: username, owner?: false, visible?: false, profile: nil)}
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
          tens?: false,
          shown: @page,
          page: @page,
          select?: false,
          selected: MapSet.new(),
          dating?: false,
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
       tens?: params["tens"] == "1",
       shown: @page
     )}
  end

  defp load(socket) do
    uuid = socket.assigns.uuid

    socket
    |> start_async(:ratings, fn -> Profile.ratings(uuid) end)
    |> start_async(:history, fn -> Profile.history(uuid) end)
  end

  defp arranged(%{assigns: a}) when is_list(a.history) do
    list = Profile.arrange(a.history, if(a.owner? or a.profile.show_ratings, do: a.ratings, else: %{}), a.kind, a.sort, a.tens?)

    if a.q == "" do
      list
    else
      q = String.downcase(a.q)
      Enum.filter(list, &String.contains?(String.downcase(&1.title || ""), q))
    end
  end

  defp arranged(_socket), do: []

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("more", _params, socket), do: {:noreply, update(socket, :shown, &(&1 + @page))}

  # Typing in the search box: the address carries it, so a search can be shared too.
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: address(socket.assigns, q: String.trim(q)), replace: true)}
  end

  # Select mode — the owner's.
  def handle_event("select_mode", _params, %{assigns: %{owner?: true}} = socket) do
    on? = not socket.assigns.select?
    {:noreply, assign(socket, select?: on?, selected: MapSet.new(), dating?: false, notice: nil)}
  end

  def handle_event("select_toggle", %{"key" => key}, %{assigns: %{owner?: true, select?: true}} = socket) do
    sel = socket.assigns.selected
    {:noreply, assign(socket, :selected, if(MapSet.member?(sel, key), do: MapSet.delete(sel, key), else: MapSet.put(sel, key)))}
  end

  # Everything the filters show, not only the page on screen.
  def handle_event("select_all", _params, %{assigns: %{owner?: true, select?: true}} = socket),
    do: {:noreply, assign(socket, :selected, MapSet.new(Enum.map(arranged(socket), & &1.key)))}

  def handle_event("select_none", _params, %{assigns: %{owner?: true}} = socket),
    do: {:noreply, assign(socket, selected: MapSet.new(), dating?: false)}

  def handle_event("date_open", _params, %{assigns: %{owner?: true, select?: true}} = socket) do
    if MapSet.size(socket.assigns.selected) > 0,
      do: {:noreply, assign(socket, dating?: true, date_error: nil)},
      else: {:noreply, socket}
  end

  def handle_event("date_close", _params, socket), do: {:noreply, assign(socket, dating?: false, date_error: nil)}

  # The chosen day goes on every title selected, in the order the list shows them.
  def handle_event("date_save", %{"date" => text}, %{assigns: %{owner?: true, select?: true}} = socket) do
    with {:ok, date} <- Date.from_iso8601(text),
         true <- Date.compare(date, Date.utc_today()) != :gt and date.year >= 1900 do
      keys = for i <- arranged(socket), MapSet.member?(socket.assigns.selected, i.key), do: i.key
      {:ok, n} = Profile.set_watched_at(socket.assigns.uuid, keys, date)

      {:noreply,
       socket
       |> assign(history: Profile.history(socket.assigns.uuid), dating?: false, selected: MapSet.new(), date_error: nil)
       |> assign(notice: "#{n} #{if n == 1, do: "title", else: "titles"} set to #{Calendar.strftime(date, "%B %-d, %Y")}.")}
    else
      _ -> {:noreply, assign(socket, :date_error, "Pick a day that has happened (not in the future).")}
    end
  end

  def handle_event("remove", _params, %{assigns: %{owner?: true, select?: true}} = socket) do
    keys = MapSet.to_list(socket.assigns.selected)
    {:ok, n} = Profile.remove_watched(socket.assigns.uuid, keys)

    {:noreply,
     socket
     |> assign(history: Profile.history(socket.assigns.uuid), selected: MapSet.new(), dating?: false)
     |> assign(notice: "#{n} #{if n == 1, do: "title", else: "titles"} taken off your watched list.")}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── async results ──────────────────────────────────────────────────

  @impl true
  def handle_async(:history, {:ok, items}, socket) when is_list(items), do: {:noreply, assign(socket, :history, items)}
  def handle_async(:history, _other, socket), do: {:noreply, assign(socket, :history, [])}
  def handle_async(:ratings, {:ok, ratings}, socket) when is_map(ratings), do: {:noreply, assign(socket, :ratings, ratings)}
  def handle_async(:ratings, _other, socket), do: {:noreply, socket}

  # ── view ───────────────────────────────────────────────────────────

  # The address of a view: the assigns, with `overrides` (a new search, a new view …) laid on.
  defp address(a, overrides) do
    v = %{sort: a.sort, kind: a.kind, tens: a.tens?, q: a.q, view: a.view} |> Map.merge(Map.new(overrides))

    query =
      Enum.flat_map([:sort, :kind, :tens, :q, :view], fn
        :sort -> if v.sort == :top, do: [sort: "top"], else: []
        :kind -> if v.kind != :all, do: [kind: Atom.to_string(v.kind)], else: []
        :tens -> if v.tens, do: [tens: "1"], else: []
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

  defp groups(items, :latest), do: Enum.chunk_by(items, &group_label/1) |> Enum.map(&{group_label(hd(&1)), &1})
  defp groups(items, _sort), do: [{nil, items}]

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
        groups: groups(shown, assigns.sort),
        today: Date.utc_today() |> Date.to_iso8601()
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@username}/watched"}
    >
      <p :if={@user == nil} class="py-24 text-center text-base-content/60">
        There is no one called <strong>{@username}</strong> here.
      </p>

      <div :if={@visible?} class={["space-y-6", @select? && "pb-28"]}>
        <div class="flex items-center gap-3">
          <.link navigate={"/#{@username}"} class="flex min-w-0 items-center gap-2 text-base-content/70 hover:text-base-content">
            <.user_avatar user={@user} size="md" />
            <span class="hidden truncate font-semibold sm:inline">{@user.username}</span>
          </.link>
          <h1 class="text-2xl font-bold sm:text-3xl">Watched</h1>
          <span :if={is_list(@history)} class="text-sm text-base-content/60">{length(@history)}</span>

          <%!-- Select mode, for the owner: one button, on and off. --%>
          <button
            :if={@owner?}
            type="button"
            phx-click="select_mode"
            aria-pressed={to_string(@select?)}
            class={["btn btn-sm ml-auto gap-1.5", @select? && "btn-primary"]}
          >
            <.icon name={if @select?, do: "hero-check", else: "hero-check-circle"} class="h-4 w-4" />
            {if @select?, do: "Done", else: "Select"}
          </button>
        </div>

        <p :if={@notice} class="rounded-box bg-success/10 px-4 py-3 text-sm text-success">{@notice}</p>

        <%!-- The search, and beside it how the list is laid out: posters or rows. --%>
        <div class="flex items-center gap-2">
          <form id="watched-search" phx-change="search" phx-submit="search" class="min-w-0 flex-1 sm:max-w-md">
            <label class="input input-bordered flex w-full items-center gap-2">
              <.icon name="hero-magnifying-glass" class="h-4 w-4 shrink-0 text-base-content/50" />
              <input type="text" name="q" value={@q} placeholder="Search what you watched…" autocomplete="off" phx-debounce="300" class="min-w-0 grow" />
            </label>
          </form>
          <div class="join shrink-0" role="group" aria-label="View">
            <.link patch={address(assigns, view: :grid)} class={["btn btn-square join-item", @view == :grid && "btn-active"]} aria-label="Grid view" title="Grid">
              <.icon name="hero-squares-2x2" class="h-5 w-5" />
            </.link>
            <.link patch={address(assigns, view: :rows)} class={["btn btn-square join-item", @view == :rows && "btn-active"]} aria-label="List view" title="List">
              <.icon name="hero-bars-3" class="h-5 w-5" />
            </.link>
          </div>
        </div>

        <%!-- The filters: one line that swipes sideways on a phone, wraps on a wide screen. --%>
        <div class="-mx-4 overflow-x-auto px-4 pb-1 [scrollbar-width:none] sm:mx-0 sm:overflow-visible sm:px-0 [&::-webkit-scrollbar]:hidden">
          <div class="flex w-max items-center gap-2 sm:w-auto sm:flex-wrap">
            <div class="join shrink-0">
              <.link
                :for={{s, label} <- [latest: "Latest", top: "By rating"]}
                patch={address(assigns, sort: s)}
                class={["btn btn-sm join-item whitespace-nowrap", @sort == s && "btn-primary"]}
              >
                {label}
              </.link>
            </div>
            <div class="join shrink-0">
              <.link
                :for={{k, label} <- Profile.kinds()}
                patch={address(assigns, kind: k)}
                class={["btn btn-sm join-item whitespace-nowrap", @kind == k && "btn-primary"]}
              >
                {label}
              </.link>
            </div>
            <.link
              :if={@owner? or @profile.show_ratings}
              patch={address(assigns, sort: :top, tens: not @tens?)}
              class={["btn btn-sm shrink-0 whitespace-nowrap", @tens? && "btn-primary"]}
            >
              ★ 10 only
            </.link>
          </div>
        </div>

        <ul :if={@history == nil} class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8" aria-busy="true">
          <li :for={_ <- 1..8} class="space-y-1">
            <div class="skeleton aspect-[2/3] w-full rounded-box"></div>
            <div class="skeleton h-4 w-3/4 rounded"></div>
          </li>
        </ul>

        <p :if={@history == []} class="text-sm text-base-content/50">
          {if @owner?, do: "Nothing finished yet. What you watch to the end shows up here.", else: "Nothing here yet."}
        </p>
        <p :if={@history != nil and @history != [] and @items == []} class="text-sm text-base-content/50">
          {if @q != "", do: "Nothing watched matches \"#{@q}\".", else: "Nothing of that kind#{if @tens?, do: " rated 10", else: ""}."}
        </p>

        <div :for={{label, group} <- @groups} class="space-y-3">
          <h2 :if={label} class="text-sm font-semibold uppercase tracking-wide text-base-content/60">{label}</h2>

          <%!-- Grid: the posters, a tick in the corner while selecting. --%>
          <ul :if={@view == :grid} class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
            <li :for={i <- group} class="space-y-1">
              <div :if={not @select?}>
                <.poster item={i} cached_titles={@cached_titles} compact />
              </div>
              <button
                :if={@select?}
                type="button"
                phx-click="select_toggle"
                phx-value-key={i.key}
                aria-pressed={to_string(MapSet.member?(@selected, i.key))}
                class={[
                  "relative block aspect-[2/3] w-full overflow-hidden rounded-box bg-base-300 shadow transition",
                  MapSet.member?(@selected, i.key) && "ring-4 ring-primary"
                ]}
              >
                <img :if={i.poster} src={Roki.Images.local(i.poster)} alt={i.title} loading="lazy" class="h-full w-full object-cover" draggable="false" />
                <span :if={!i.poster} class="flex h-full items-center justify-center p-2 text-center text-xs">{i.title}</span>
                <.tick selected={MapSet.member?(@selected, i.key)} />
              </button>
              <div class="flex items-center justify-between text-xs text-base-content/50">
                <span>{day(i)}</span>
                <span :if={i.score != nil and (@owner? or @profile.show_ratings)} class="font-semibold text-warning">★ {Profile.score_text(i.score)}</span>
              </div>
            </li>
          </ul>

          <%!-- Rows: one to a line, with what you would want to know. --%>
          <ul :if={@view == :rows} class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300">
            <li :for={i <- group}>
              <.row item={i} select?={@select?} selected={MapSet.member?(@selected, i.key)} show_score={@owner? or @profile.show_ratings} />
            </li>
          </ul>
        </div>

        <button :if={length(@items) > @shown} phx-click="more" class="btn btn-ghost btn-sm">
          Show {min(length(@items) - @shown, @page)} more
        </button>
      </div>

      <%!-- Select mode's bar: how many and which, then what to do with them. Two lines on a
            phone, one on a wide screen. --%>
      <div :if={@select?} class="fixed inset-x-0 bottom-0 z-40 border-t border-base-300 bg-base-100/95 px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-3 shadow-[0_-8px_24px_-12px_rgba(0,0,0,0.3)] backdrop-blur">
        <div class="mx-auto max-w-6xl space-y-3 sm:flex sm:items-center sm:gap-4 sm:space-y-0">
          <div class="flex items-center gap-1 sm:flex-1">
            <p class="min-w-0 flex-1 text-sm"><b>{MapSet.size(@selected)}</b> selected</p>
            <button type="button" phx-click="select_all" class="btn btn-ghost btn-sm whitespace-nowrap">All {length(@items)}</button>
            <button type="button" phx-click="select_none" class="btn btn-ghost btn-sm" disabled={MapSet.size(@selected) == 0}>None</button>
          </div>
          <div class="grid grid-cols-2 gap-2 sm:flex">
            <button type="button" phx-click="date_open" class="btn btn-primary whitespace-nowrap" disabled={MapSet.size(@selected) == 0}>
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
      <div :if={@owner? and @dating?} class="fixed inset-0 z-50 flex items-end justify-center sm:items-center" role="dialog" aria-modal="true" aria-label="Edit watch date">
        <div class="absolute inset-0 bg-black/60" phx-click="date_close"></div>
        <form id="date-form" phx-submit="date_save" class="relative w-full max-w-md space-y-4 rounded-t-box bg-base-100 p-5 pb-[max(1.25rem,env(safe-area-inset-bottom))] shadow-2xl sm:rounded-box">
          <div>
            <h2 class="text-lg font-semibold">When did you watch {if MapSet.size(@selected) == 1, do: "it", else: "them"}?</h2>
            <p class="text-sm text-base-content/60">
              {MapSet.size(@selected)} {if MapSet.size(@selected) == 1, do: "title", else: "titles"} will be put on this day in your history — anywhere back, years if you like. They keep the order they have now.
            </p>
          </div>
          <input type="date" name="date" required min="1900-01-01" max={@today} class="input input-bordered w-full" autofocus />
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
  defp tick(assigns) do
    ~H"""
    <span class={[
      "absolute right-1.5 top-1.5 flex h-6 w-6 items-center justify-center rounded-full border-2 shadow",
      if(@selected, do: "border-primary bg-primary text-primary-content", else: "border-white bg-black/30 text-transparent")
    ]}>
      <.icon name="hero-check-micro" class="h-4 w-4" />
    </span>
    """
  end

  attr :item, :map, required: true
  attr :select?, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :show_score, :boolean, default: true

  # One title as a line: a small poster, its name, what kind and which year, and on the right
  # the owner's rating and the day.
  defp row(assigns) do
    assigns = assign(assigns, href: href(assigns.item))

    ~H"""
    <%= if @select? do %>
      <button
        type="button"
        phx-click="select_toggle"
        phx-value-key={@item.key}
        aria-pressed={to_string(@selected)}
        class={["flex w-full items-center gap-3 p-2 text-left transition hover:bg-base-200 sm:p-3", @selected && "bg-primary/10"]}
      >
        <.row_body item={@item} show_score={@show_score} />
        <span class={[
          "flex h-6 w-6 shrink-0 items-center justify-center rounded-full border-2",
          if(@selected, do: "border-primary bg-primary text-primary-content", else: "border-base-content/30 text-transparent")
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
      <img :if={@item.poster} src={Roki.Images.local(@item.poster)} alt="" loading="lazy" class="h-full w-full object-cover" draggable="false" />
    </div>
    <div class="min-w-0 flex-1">
      <div class="truncate font-medium">{@item.title}</div>
      <div class="truncate text-sm text-base-content/60">
        {kind_label(@item)}<span :if={@item.year}> · {@item.year}</span>
      </div>
      <div class="text-xs text-base-content/50 sm:hidden">{day(@item)}</div>
    </div>
    <div class="shrink-0 text-right">
      <div :if={@item.score != nil and @show_score} class="font-semibold text-warning">★ {Profile.score_text(@item.score)}</div>
      <div :if={@item.score == nil and @show_score} class="text-sm text-base-content/30">not rated</div>
      <div class="hidden text-sm text-base-content/60 sm:block">{day(@item) || "No date"}</div>
    </div>
    """
  end
end
