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
    changed? = sort != socket.assigns.sort or socket.assigns.page == 0

    socket = assign(socket, sort: sort, size: size)

    {:noreply,
     if(connected?(socket) and changed?,
       do:
         socket
         |> assign(items: [], page: 0, more?: false, loading?: true, error: nil)
         |> fetch(1),
       else: socket
     )}
  end

  defp fetch(socket, n) do
    %{kind: kind, sort: sort, uuid: uuid} = socket.assigns

    start_async(socket, {:page, sort, n}, fn ->
      case Browse.page(kind, sort, n, uuid) do
        {:ok, items, more?} -> {:ok, n, items, more?, Roki.Laev.seen_keys(uuid, items)}
        error -> error
      end
    end)
  end

  @impl true
  def handle_event("more", _params, %{assigns: %{more?: true, loading?: false}} = socket),
    do: {:noreply, socket |> assign(:loading?, true) |> fetch(socket.assigns.page + 1)}

  def handle_event("more", _params, socket), do: {:noreply, socket}

  # Order and size live in the address, so a view can be linked to and the back button works.
  def handle_event("sort", %{"sort" => sort}, socket),
    do: {:noreply, push_patch(socket, to: view_path(socket, sort: Browse.sort(sort)))}

  def handle_event("size", %{"size" => size}, socket) when size in @sizes do
    {:noreply, socket |> assign(:size, size) |> push_event("roki:grid", %{size: size})}
  end

  defp view_path(socket, overrides) do
    query =
      [sort: socket.assigns.sort]
      |> Keyword.merge(overrides)
      |> Enum.reject(fn {_, v} -> v == :popular end)

    base = "/#{socket.assigns.kind}"
    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  @impl true
  def handle_async({:page, sort, _n}, _result, %{assigns: %{sort: current}} = socket)
      when sort != current,
      do: {:noreply, socket}

  def handle_async({:page, _sort, _n}, {:ok, {:ok, n, items, more?, seen}}, socket) do
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
      if socket.assigns.sort == :popular,
        do: start_async(socket, {:dates, n}, fn -> Roki.Watch.upcoming(uuid, fresh) end),
        else: socket

    {:noreply, socket}
  end

  def handle_async({:page, _sort, _n}, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, loading?: false, error: reason)}

  def handle_async({:page, _sort, _n}, {:exit, reason}, socket),
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
        sorts: Browse.sorts()
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@kind}"}
    >
      <div class="flex flex-wrap items-center gap-3">
        <h1 class="flex-1 text-2xl font-bold tracking-tight sm:text-3xl">{@title}</h1>

        <form id="sort-form" phx-change="sort" class="contents">
          <select name="sort" class="select select-sm select-bordered w-auto" aria-label="Order">
            <option :for={{key, label} <- @sorts} value={key} selected={@sort == key}>
              {label}
            </option>
          </select>
        </form>

        <div class="join" role="group" aria-label="Grid size">
          <button
            :for={{size, label} <- [{"s", "Small"}, {"m", "Medium"}, {"l", "Large"}]}
            phx-click="size"
            phx-value-size={size}
            title={"#{label} posters"}
            aria-label={"#{label} posters"}
            class={["btn btn-sm btn-square join-item", @size == size && "btn-active"]}
          >
            <.size_icon size={size} />
          </button>
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
