defmodule RokiWeb.MoodLive do
  @moduledoc """
  `/mood/:slug` — one feeling (`Roki.Mood`) across films, shows and anime at once: a band in
  the mood's colour, then the titles in a grid that grows as it is scrolled. Narrowed to one
  kind, ordered by popularity, date or score, or searched within — all in the address.
  """
  use RokiWeb, :live_view

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Mood

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Mood.get(slug) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/home")}

      mood ->
        scope = socket.assigns[:phoenix_kit_current_scope]
        uuid = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)

        {:ok,
         assign(socket,
           mood: mood,
           page_title: mood.label,
           # Its animation over the top (mood_fx.js): not for a season, which has none.
           fx?: Application.get_env(:roki, :mood_fx, true) and not Map.has_key?(mood, :season),
           uuid: uuid,
           client: RokiWeb.Client.key(socket, uuid),
           kind: :all,
           sort: :popular,
           q: "",
           items: [],
           page: 0,
           more?: false,
           loading?: true,
           found: nil,
           searching?: false,
           error: nil,
           seen: MapSet.new(),
           upcoming: %{},
           place: RokiWeb.Place.from_params(socket),
           place_y: nil
         )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = Mood.kind(params["kind"])
    sort = Mood.sort(params["sort"])
    q = params["q"] |> to_string() |> String.trim() |> String.slice(0, 80)
    a = socket.assigns
    changed? = kind != a.kind or sort != a.sort or q != a.q or a.page == 0

    socket = assign(socket, kind: kind, sort: sort, q: q)

    socket =
      if changed?,
        do:
          socket
          |> assign(items: [], page: 0, more?: false, loading?: true, error: nil, found: nil)
          |> show_held(),
        else: socket

    cond do
      not connected?(socket) -> {:noreply, socket}
      changed? and q != "" -> {:noreply, search(socket)}
      changed? -> {:noreply, fetch_first(socket)}
      true -> {:noreply, socket}
    end
  end

  # What is already held of this list is drawn in the very first render; the person's own marks
  # are filled in once worked out.
  defp show_held(%{assigns: %{q: q}} = socket) when q != "", do: socket

  defp show_held(%{assigns: a} = socket) do
    upto = with %{pages: pages} <- a.place, do: pages, else: (_ -> 1)
    held = for n <- 1..upto, do: Mood.peek(a.mood.slug, a.kind, a.sort, n)

    if Enum.all?(held, &match?({:ok, _, _}, &1)) do
      {:ok, _, more?} = List.last(held)

      assign(socket,
        items: Enum.flat_map(held, fn {:ok, items, _} -> items end),
        page: upto,
        more?: more?,
        loading?: false
      )
    else
      socket
    end
  end

  defp fetch_first(%{assigns: %{place: %{pages: pages, y: y}}} = socket),
    do: socket |> assign(place: nil, place_y: y) |> fetch(1, pages)

  defp fetch_first(socket), do: fetch(socket, 1)

  defp fetch(socket, n, upto \\ nil) do
    %{mood: mood, kind: kind, sort: sort, uuid: uuid} = socket.assigns
    last = upto || n
    view = {kind, sort}

    start_async(socket, {:page, view, last}, fn ->
      results =
        if last > n,
          do: RokiWeb.Place.pages(last, &Mood.page(mood.slug, kind, sort, &1, uuid)),
          else: [Mood.page(mood.slug, kind, sort, n, uuid)]

      case Enum.find(results, &(not match?({:ok, _, _}, &1))) do
        nil ->
          items = Enum.flat_map(results, fn {:ok, items, _} -> items end)
          {:ok, _, more?} = List.last(results)
          {:ok, last, Roki.Laev.annotate(uuid, items), more?, Roki.Laev.seen_keys(uuid, items)}

        error ->
          error
      end
    end)
  end

  defp search(socket) do
    %{mood: mood, q: q, uuid: uuid, client: client} = socket.assigns

    socket
    |> assign(searching?: true, loading?: false)
    |> start_async({:search, q}, fn ->
      with {:ok, items} <- Mood.search(client, uuid, q, mood) do
        {:ok, Roki.Laev.annotate(uuid, items), Roki.Laev.seen_keys(uuid, items)}
      end
    end)
  end

  @impl true
  def handle_async({:page, view, _n}, _result, %{assigns: %{kind: kind, sort: sort}} = socket)
      when view != {kind, sort},
      do: {:noreply, socket}

  def handle_async({:page, _view, _n}, {:ok, {:ok, n, items, more?, seen}}, socket) do
    by_key = Map.new(items, &{{&1.type, &1.id}, &1})
    shown = Enum.map(socket.assigns.items, &Map.get(by_key, {&1.type, &1.id}, &1))
    known = MapSet.new(socket.assigns.items, &{&1.type, &1.id})
    fresh = Enum.reject(items, &MapSet.member?(known, {&1.type, &1.id}))
    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(
       items: shown ++ fresh,
       page: n,
       more?: more?,
       loading?: false,
       seen: MapSet.union(socket.assigns.seen, seen)
     )
     |> start_async({:dates, n}, fn -> Roki.Watch.upcoming(uuid, fresh) end)}
  end

  def handle_async({:page, _view, _n}, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, loading?: false, error: reason)}

  def handle_async({:page, _view, _n}, {:exit, reason}, socket),
    do: {:noreply, assign(socket, loading?: false, error: reason)}

  def handle_async({:search, q}, {:ok, {:ok, items, seen}}, %{assigns: %{q: q}} = socket),
    do:
      {:noreply,
       assign(socket,
         found: items,
         searching?: false,
         seen: MapSet.union(socket.assigns.seen, seen)
       )}

  def handle_async({:search, q}, _other, %{assigns: %{q: q}} = socket),
    do: {:noreply, assign(socket, found: [], searching?: false)}

  def handle_async({:search, _q}, _other, socket), do: {:noreply, socket}

  def handle_async({:dates, _n}, {:ok, found}, socket),
    do: {:noreply, update(socket, :upcoming, &Map.merge(&1, found))}

  def handle_async({:dates, _n}, _other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("more", _params, %{assigns: %{more?: true, loading?: false, q: ""}} = socket),
    do: {:noreply, socket |> assign(:loading?, true) |> fetch(socket.assigns.page + 1)}

  def handle_event("more", _params, socket), do: {:noreply, socket}
  def handle_event("placed", _params, socket), do: {:noreply, assign(socket, :place_y, nil)}

  def handle_event("kind", %{"kind" => kind}, socket),
    do: {:noreply, push_patch(socket, to: view_path(socket, kind: Mood.kind(kind)))}

  def handle_event("sort", %{"sort" => sort}, socket),
    do: {:noreply, push_patch(socket, to: view_path(socket, sort: Mood.sort(sort)))}

  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, push_patch(socket, to: view_path(socket, q: q))}

  def handle_event("clear", _params, socket),
    do: {:noreply, push_patch(socket, to: view_path(socket, q: ""))}

  defp view_path(%{assigns: a}, changes) do
    view = Map.merge(%{kind: a.kind, sort: a.sort, q: a.q}, Map.new(changes))

    query =
      [
        kind: view.kind != :all && view.kind,
        sort: view.sort != :popular && view.sort,
        q: view.q != "" && view.q
      ]
      |> Enum.filter(fn {_, v} -> v end)

    ~p"/mood/#{a.mood.slug}?#{query}"
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        grid: RokiWeb.GridSize.cols(assigns.grid_size),
        hue: assigns.mood.hue,
        lead: Enum.find(assigns.items, & &1[:backdrop])
      )

    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      flush
      bleed
      overlay
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/mood/#{@mood.slug}"}
    >
      <%!-- The top, as on the home page's carousel: the mood's picture blurred into a dark field of
            its colour under the floating header, the name in the site's own face with the mood's
            colour in the line above it, and the ways to narrow as glass pills. The picture is the
            backdrop of the first title. Dark in both themes. --%>
      <%!-- The mood's animation from the home page goes on over this top (mood_fx.js), a little
            lighter, thinning out as the page scrolls into the grid. --%>
      <div
        id="mood-fx"
        phx-hook={@fx? && "MoodFx"}
        data-mood={@mood.slug}
        data-amount="0.7"
        class="relative"
      >
        <canvas
          :if={@fx?}
          id="mood-fx-canvas"
          phx-update="ignore"
          class="pointer-events-none absolute left-0 top-0 z-[25]"
          aria-hidden="true"
        ></canvas>
        <section
          data-fx-stage
          class="relative z-20 flex min-h-[clamp(20rem,46svh,28rem)] flex-col justify-end text-white"
        >
          <div class="absolute inset-0 -z-10 overflow-hidden bg-neutral-950">
            <img
              :if={@lead}
              src={Roki.Images.local(String.replace(@lead.backdrop, "/w1280/", "/w780/"))}
              alt=""
              class="absolute inset-0 h-full w-full scale-110 object-cover opacity-50 blur-lg"
            />
            <div
              class="absolute inset-0"
              style={"background: radial-gradient(ellipse at 75% 30%, transparent 0%, hsl(#{@hue} 25% 6%) 78%), linear-gradient(0deg, hsl(#{@hue} 25% 5%) 0%, transparent 45%), linear-gradient(180deg, rgb(0 0 0 / 0.55) 0%, transparent 22%)"}
            >
            </div>
          </div>

          <div class="flex flex-col gap-6 px-4 pb-8 pt-28 sm:px-6 lg:px-12 xl:px-16">
            <div class="max-w-xl sm:max-w-3xl lg:max-w-4xl">
              <p
                class="flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.25em]"
                style={"color: hsl(#{@hue} 90% 62%)"}
              >
                <%= if @mood[:season] do %>
                  <.icon name="hero-calendar-days" class="h-4 w-4" /> In season now
                <% else %>
                  <span class="tabular-nums">{Roki.Mood.number(@mood)}</span>
                  <span aria-hidden="true">·</span> Tonight I want to
                <% end %>
              </p>
              <h1 class="mt-3 text-5xl font-bold leading-none tracking-tight sm:text-6xl lg:text-7xl">
                {@mood.label}
              </h1>
              <p class="mt-4 max-w-lg text-base text-white/70 sm:text-lg">{@mood.tagline}</p>
            </div>

            <div class="flex flex-col gap-3 lg:flex-row lg:items-center">
              <%!-- A season is made of keywords, which a search result does not carry, so there is nothing to
                  keep a search to: the box is only for moods. --%>
              <form
                :if={!@mood[:season]}
                phx-submit="search"
                class="flex w-full max-w-xl gap-2 lg:w-96"
              >
                <label class="flex h-11 min-w-0 flex-1 items-center gap-2 rounded-full border border-white/25 bg-black/30 px-4 text-white backdrop-blur-md focus-within:border-white/60">
                  <.icon name="hero-magnifying-glass" class="h-5 w-5 shrink-0 opacity-70" />
                  <input
                    type="search"
                    name="q"
                    value={@q}
                    placeholder={"Search #{String.downcase(@mood.label)}…"}
                    autocomplete="off"
                    class="w-full bg-transparent text-white placeholder:text-white/60 focus:outline-none"
                  />
                </label>
                <button
                  type="submit"
                  class="btn h-11 min-h-0 rounded-full border-0 bg-white px-5 text-neutral-900 hover:bg-white/90"
                >
                  Find
                </button>
              </form>

              <div class="flex flex-wrap items-center gap-2">
                <div
                  class="inline-flex rounded-full border border-white/25 bg-black/30 p-1 backdrop-blur-md"
                  role="group"
                  aria-label="Kind"
                >
                  <button
                    :for={
                      {k, label} <- [
                        all: "Everything",
                        movies: "Movies",
                        shows: "Shows",
                        anime: "Anime"
                      ]
                    }
                    type="button"
                    phx-click="kind"
                    phx-value-kind={k}
                    aria-pressed={to_string(@kind == k)}
                    class={[
                      "rounded-full px-3.5 py-1.5 text-sm font-semibold transition",
                      @kind == k && "bg-white text-neutral-900 shadow",
                      @kind != k && "text-white/80 hover:text-white"
                    ]}
                  >
                    {label}
                  </button>
                </div>
                <div
                  :if={@q == ""}
                  class="inline-flex rounded-full border border-white/25 bg-black/30 p-1 backdrop-blur-md"
                  role="group"
                  aria-label="Order"
                >
                  <button
                    :for={{s, label} <- Mood.sorts()}
                    type="button"
                    phx-click="sort"
                    phx-value-sort={s}
                    aria-pressed={to_string(@sort == s)}
                    class={[
                      "rounded-full px-3.5 py-1.5 text-sm font-semibold transition",
                      @sort == s && "bg-white text-neutral-900 shadow",
                      @sort != s && "text-white/80 hover:text-white"
                    ]}
                  >
                    {label}
                  </button>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>

      <%!-- Below the picture: the page's gutters, and the hover cards' hook round every list. --%>
      <div
        id="mood-cards"
        phx-hook="GridCards"
        class="space-y-4 px-4 pb-12 pt-6 [overflow-x:clip] sm:px-6 lg:px-12 xl:px-16"
      >
        <p :if={@error} class="alert alert-error text-sm">
          Couldn't reach TMDB just now. Try again in a minute.
        </p>

        <div class="flex justify-end">
          <RokiWeb.GridSize.grid_switch size={@grid_size} />
        </div>

        <%!-- A search within the mood: its finds, in place of the list. --%>
        <section :if={@q != ""} class="space-y-3">
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <h2 class="text-xl font-semibold">“{@q}” in {String.downcase(@mood.label)}</h2>
            <button type="button" phx-click="clear" class="text-sm text-primary hover:underline">Clear</button>
          </div>
          <div :if={@searching?} class="flex items-center gap-3 py-10 text-base-content/60">
            <span class="loading loading-spinner"></span> Looking…
          </div>
          <p
            :if={@found == [] and not @searching?}
            class="rounded-box border border-dashed border-base-300 px-4 py-10 text-center text-base-content/60"
          >
            Nothing by that name here. It may be in another mood — <.link
              navigate={~p"/search?#{[q: @q]}"}
              class="text-primary hover:underline"
            >search everything</.link>.
          </p>
          <ul :if={is_list(@found) and @found != []} class={["grid gap-4", @grid]}>
            <RokiWeb.FeaturedLive.grid_card
              :for={i <- @found}
              kind={:mood_found}
              item={i}
              seen={MapSet.member?(@seen, {i.type, i.id})}
              upcoming={@upcoming}
              signed_in?={@uuid != nil}
            />
          </ul>
        </section>

        <ul
          :if={@q == "" and @items == [] and @loading?}
          class={["grid gap-4", @grid]}
          aria-busy="true"
        >
          <li :for={_ <- 1..12} class="skeleton aspect-[2/3] w-full rounded-box"></li>
        </ul>

        <ul
          :if={@q == "" and @items != []}
          id="grid"
          phx-hook="FillGrid"
          data-more={to_string(@more?)}
          data-page={@page}
          data-restore-y={@place_y}
          class={["grid gap-4", @grid]}
        >
          <RokiWeb.FeaturedLive.grid_card
            :for={i <- @items}
            kind={:mood}
            item={i}
            seen={MapSet.member?(@seen, {i.type, i.id})}
            upcoming={@upcoming}
            signed_in?={@uuid != nil}
          />
        </ul>

        <div
          :if={@q == "" and @items != [] and (@more? or @loading?)}
          id="grid-more"
          phx-hook="InfiniteScroll"
          data-event="more"
          data-active={to_string(@more? and not @loading?)}
          class="flex min-h-16 items-center justify-center pt-4"
        >
          <span :if={@loading?} class="loading loading-spinner loading-md text-base-content/50"></span>
        </div>

        <p
          :if={@q == "" and @items == [] and not @loading? and @error == nil}
          class="py-16 text-center text-base-content/60"
        >
          Nothing here.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
