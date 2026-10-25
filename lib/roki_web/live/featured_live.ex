defmodule RokiWeb.FeaturedLive do
  @moduledoc """
  `/home` — what is popular right now: movies, shows and anime. Public; the
  same page for a visitor and a signed-in user, with the pitch on top only for
  a visitor. Each shelf ends in a poster-sized "Load more" tile that loads the next
  TMDB page, like laev's Featured screen. A signed-in user who has connected
  laev sees what they have already watched greyed out.
  """
  use RokiWeb, :live_view

  import RokiWeb.ListComponents
  import RokiWeb.PosterComponents

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Featured

  @titles %{movies: "Trending movies", shows: "Trending shows", anime: "Anime airing now"}

  @impl true
  def mount(_params, _session, socket) do
    shelves =
      Map.new(Featured.kinds(), &{&1, %{items: [], page: 0, more?: false, loading?: true}})

    socket =
      socket
      |> assign(:page_title, "Featured")
      |> assign(:shelves, shelves)
      |> assign(:error, nil)
      |> assign(:seen, MapSet.new())
      |> assign(:upcoming, %{})
      |> assign(:uuid, uuid(socket))
      |> assign(:activity, if(uuid(socket), do: nil, else: []))
      |> assign(:lists, Enum.map(Roki.Lists.summaries(), &Map.put(&1, :watched, nil)))

    {:ok, if(connected?(socket), do: start(socket), else: socket)}
  end

  # Who finished what, newest first. Only for people signed in (it names other people); it stays
  # up to date: a finish anywhere tells every open page.
  defp load_activity(socket) do
    if socket.assigns.uuid,
      do: start_async(socket, :activity, fn -> Roki.Activity.recent(14) end),
      else: socket
  end

  @impl true
  def handle_info(:activity, socket), do: {:noreply, load_activity(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  defp start(socket) do
    %{uuid: uuid, lists: lists} = socket.assigns
    socket = Enum.reduce(Featured.kinds(), socket, &fetch(&2, &1, 1))

    if uuid, do: Phoenix.PubSub.subscribe(Roki.PubSub, Roki.Activity.topic())
    socket = load_activity(socket)

    # How far through each list a signed-in user is — static data, so it never waits on TMDB.
    if uuid,
      do: start_async(socket, :progress, fn -> Roki.Lists.with_progress(uuid, lists) end),
      else: socket
  end

  defp uuid(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)
  end

  # What this user has already seen is worked out alongside the page of titles,
  # so a watched poster arrives greyed rather than flashing in full colour.
  defp fetch(socket, kind, page) do
    uuid = socket.assigns.uuid

    start_async(socket, {:page, kind}, fn ->
      case Featured.page(kind, page, uuid) do
        {:ok, items, more?} ->
          {page, {:ok, Roki.Laev.annotate(uuid, items), more?}, Roki.Laev.seen_keys(uuid, items)}

        error ->
          {page, error, MapSet.new()}
      end
    end)
  end

  @impl true
  def handle_async({:page, kind}, {:ok, {page, {:ok, items, more?}, seen}}, socket) do
    shelf = socket.assigns.shelves[kind]
    known = MapSet.new(shelf.items, & &1.id)
    fresh = Enum.reject(items, &MapSet.member?(known, &1.id))
    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(:seen, MapSet.union(socket.assigns.seen, seen))
     |> start_async({:dates, kind, page}, fn -> Roki.Watch.upcoming(uuid, fresh) end)
     |> put_shelf(kind, %{
       shelf
       | items: shelf.items ++ fresh,
         page: page,
         more?: more?,
         loading?: false
     })}
  end

  def handle_async({:page, kind}, {:ok, {_page, {:error, reason}, _seen}}, socket),
    do: {:noreply, failed(socket, kind, reason)}

  # Dates of what is not out yet arrive after the posters, and only add a mark to them.
  def handle_async({:dates, _kind, _page}, {:ok, found}, socket),
    do: {:noreply, update(socket, :upcoming, &Map.merge(&1, found))}

  def handle_async({:dates, _kind, _page}, _other, socket), do: {:noreply, socket}

  def handle_async(:activity, {:ok, runs}, socket),
    do: {:noreply, assign(socket, :activity, runs)}

  def handle_async(:activity, _other, socket), do: {:noreply, socket}

  def handle_async(:progress, {:ok, lists}, socket), do: {:noreply, assign(socket, :lists, lists)}
  def handle_async(:progress, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async({:page, kind}, {:exit, reason}, socket),
    do: {:noreply, failed(socket, kind, reason)}

  defp ago(%DateTime{} = at) do
    s = DateTime.diff(DateTime.utc_now(), at)

    cond do
      s < 90 -> "just now"
      s < 3600 -> "#{div(s, 60)} min ago"
      s < 86_400 -> "#{div(s, 3600)} h ago"
      true -> "#{div(s, 86_400)} d ago"
    end
  end

  defp failed(socket, kind, reason) do
    socket
    |> put_shelf(kind, %{socket.assigns.shelves[kind] | loading?: false})
    |> assign(:error, reason)
  end

  defp put_shelf(socket, kind, shelf),
    do: assign(socket, :shelves, Map.put(socket.assigns.shelves, kind, shelf))

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:visitor?, assigns.uuid == nil)
      |> assign(:titles, @titles)
      |> assign(
        :loading?,
        Enum.any?(assigns.shelves, fn {_k, s} -> s.loading? and s.items == [] end)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/home"
    >
      <section :if={@visitor?} class="py-10 text-center">
        <div class="mx-auto max-w-xl space-y-4">
          <h1 class="text-3xl font-bold tracking-tight sm:text-4xl">
            Everything you watch, in one place.
          </h1>
          <p class="text-base-content/70">
            Films, shows and anime — your watchlist and where you stopped, following you from the
            terminal to the browser.
          </p>
          <div class="flex justify-center gap-3">
            <a href="/phoenix_kit/users/register" class="btn btn-primary">Create an account</a>
            <a href="/phoenix_kit/users/log-in" class="btn btn-ghost">Log in</a>
          </div>
        </div>
      </section>

      <h1 :if={!@visitor?} class="text-2xl font-bold tracking-tight sm:text-3xl">Featured</h1>

      <%!-- What people finished lately, newest on the left. Room is kept while it loads. --%>
      <section :if={@activity != []} class="space-y-2" aria-label="Recent activity">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
          Recent activity
        </h2>
        <div :if={@activity == nil} class="skeleton h-24 w-full rounded-box"></div>
        <ul :if={@activity} class="-mx-1 flex gap-3 overflow-x-auto px-1 pb-2">
          <li :for={run <- @activity} class="shrink-0">
            <.link
              navigate={~p"/title/#{run.type}/#{run.tmdb_id}"}
              class="flex h-24 w-64 gap-3 rounded-box bg-base-200 p-2 transition hover:bg-base-300"
            >
              <img
                :if={run.poster}
                src={run.poster}
                alt=""
                loading="lazy"
                class="aspect-[2/3] h-full rounded-md bg-base-300 object-cover"
              />
              <div :if={!run.poster} class="aspect-[2/3] h-full rounded-md bg-base-300"></div>
              <div class="min-w-0 flex-1 text-sm leading-snug">
                <p class="line-clamp-3">
                  <span class="font-semibold">{run.username}</span>
                  {Roki.Activity.verb(run)}
                  <span class="font-semibold">{run.title}</span>
                </p>
                <p class="mt-0.5 text-xs text-base-content/50">{ago(run.at)}</p>
              </div>
            </.link>
          </li>
        </ul>
      </section>

      <div
        :if={@loading? and @error == nil}
        class="flex items-center justify-center gap-3 py-24 text-base-content/60"
      >
        <span class="loading loading-spinner"></span> Loading what's popular…
      </div>

      <p :if={@error == :no_tmdb_key} class="alert text-sm">
        Featured needs a TMDB key — set <code>TMDB_API_KEY</code> on the server.
      </p>
      <p :if={@error not in [nil, :no_tmdb_key]} class="alert alert-error text-sm">
        Couldn't reach TMDB just now. Try again in a minute.
      </p>

      <div class="space-y-10">
        <.shelf
          :for={kind <- [:movies, :shows, :anime]}
          kind={kind}
          title={@titles[kind]}
          shelf={@shelves[kind]}
          seen={@seen}
          upcoming={@upcoming}
          cached_titles={@cached_titles}
        />

        <%!-- Last, and only once the shelves above have settled, so it can never push
              anything down. Curated franchises and TMDB collections, start to finish. --%>
        <section :if={not @loading?} class="space-y-3">
          <div class="flex items-baseline justify-between gap-3">
            <h2 class="text-xl font-semibold">Lists</h2>
            <p class="hidden text-sm text-base-content/60 sm:block">
              Franchises start to finish, in release order
            </p>
          </div>
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <.list_card :for={l <- @lists} list={l} />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :kind, :atom, required: true
  attr :title, :string, required: true
  attr :shelf, :map, required: true
  attr :seen, :any, required: true
  attr :upcoming, :map, default: %{}
  attr :cached_titles, :any, default: nil

  defp shelf(assigns) do
    ~H"""
    <section :if={@shelf.items != []} class="space-y-3">
      <div class="flex items-baseline justify-between gap-3">
        <h2 class="text-xl font-semibold">{@title}</h2>
        <.link
          navigate={"/#{@kind}"}
          class="btn btn-sm btn-primary btn-outline gap-1.5 rounded-full px-4"
        >
          See more <.icon name="hero-arrow-right" class="h-4 w-4" />
        </.link>
      </div>
      <%!-- Two rows: the rest of the list is on its own page, so this one stays short. --%>
      <ul class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
        <li :for={i <- Enum.take(@shelf.items, 16)} class="space-y-1">
          <.poster
            item={i}
            seen={MapSet.member?(@seen, {i.type, i.id})}
            cached_titles={@cached_titles}
            upcoming={@upcoming}
            compact
          />
        </li>
      </ul>
    </section>
    """
  end
end
