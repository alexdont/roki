defmodule RokiWeb.SearchLive do
  @moduledoc """
  `/search?q=` — find a movie or show. Public. Results are a poster grid ending
  in a poster-sized "More" tile that loads the next TMDB page; above the first
  page sit any franchise lists the results belong to (a curated laev list or a
  TMDB collection). A signed-in user who has connected laev searches with their
  own TMDB key and sees what they have already watched greyed out.

  Searching is throttled — see `Roki.Search`.
  """
  use RokiWeb, :live_view

  import RokiWeb.ListComponents
  import RokiWeb.PosterComponents

  alias PhoenixKit.Users.Auth.Scope

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    uuid = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)

    {:ok,
     socket
     |> assign(:page_title, "Search")
     |> assign(:uuid, uuid)
     |> assign(:client, RokiWeb.Client.key(socket, uuid))
     |> assign(:q, "")
     |> assign(:shelf, empty())
     |> assign(:franchises, [])
     |> assign(:seen, MapSet.new())
     |> assign(:error, nil)}
  end

  defp empty, do: %{items: [], page: 0, more?: false, loading?: false, searched?: false}

  @impl true
  def handle_params(params, _uri, socket) do
    q = params |> Map.get("q", "") |> Roki.Search.clean()

    cond do
      q == socket.assigns.q ->
        {:noreply, socket}

      String.length(q) < 2 ->
        {:noreply,
         assign(socket, q: q, shelf: empty(), franchises: [], seen: MapSet.new(), error: nil)}

      true ->
        {:noreply,
         socket |> assign(q: q, franchises: [], seen: MapSet.new(), error: nil) |> fetch(1, true)}
    end
  end

  defp fetch(socket, page, fresh?) do
    %{q: q, uuid: uuid, client: client} = socket.assigns

    shelf =
      if fresh?,
        do: %{empty() | loading?: true, searched?: true},
        else: %{socket.assigns.shelf | loading?: true}

    socket
    |> assign(:shelf, shelf)
    |> start_async(:search, fn -> {q, page, Roki.Search.search(client, uuid, q, page)} end)
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/search?#{[q: q]}")}

  def handle_event("more", _params, socket) do
    case socket.assigns.shelf do
      %{more?: true, loading?: false, page: page} -> {:noreply, fetch(socket, page + 1, false)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(
        :search,
        {:ok, {q, page, {:ok, items, more?, franchises, seen}}},
        %{assigns: %{q: q}} = socket
      ) do
    shelf = socket.assigns.shelf
    known = MapSet.new(shelf.items, &{&1.type, &1.id})
    fresh = Enum.reject(items, &MapSet.member?(known, {&1.type, &1.id}))

    {:noreply,
     socket
     |> assign(:seen, MapSet.union(socket.assigns.seen, seen))
     |> assign(:franchises, if(page == 1, do: franchises, else: socket.assigns.franchises))
     |> assign(:shelf, %{
       shelf
       | items: shelf.items ++ fresh,
         page: page,
         more?: more?,
         loading?: false
     })}
  end

  def handle_async(:search, {:ok, {q, _page, {:error, reason}}}, %{assigns: %{q: q}} = socket),
    do:
      {:noreply, assign(socket, error: reason, shelf: %{socket.assigns.shelf | loading?: false})}

  # An answer for a query the user has since replaced — success or failure.
  def handle_async(:search, {:ok, {_old_q, _page, _result}}, socket), do: {:noreply, socket}

  def handle_async(:search, {:exit, reason}, socket),
    do:
      {:noreply, assign(socket, error: reason, shelf: %{socket.assigns.shelf | loading?: false})}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/search"
    >
      <form phx-submit="search" role="search" class="mx-auto flex max-w-2xl gap-2 pb-2">
        <input
          type="search"
          name="q"
          value={@q}
          placeholder="Search movies and shows — or paste an IMDb id"
          autocomplete="off"
          autofocus
          maxlength="120"
          class="input input-bordered w-full"
        />
        <button type="submit" class="btn btn-primary">Search</button>
      </form>

      <p :if={@q == ""} class="py-16 text-center text-base-content/60">
        Search by title. Add a year to narrow it — <code>heat 1995</code>.
      </p>
      <p :if={@q != "" and String.length(@q) < 2} class="py-16 text-center text-base-content/60">
        Type at least two characters.
      </p>

      <div
        :if={@shelf.loading? and @shelf.items == []}
        class="flex justify-center gap-3 py-24 text-base-content/60"
      >
        <span class="loading loading-spinner"></span> Searching…
      </div>

      <p :if={@error == :no_tmdb_key} class="alert text-sm">
        Search needs a TMDB key — set <code>TMDB_API_KEY</code>
        on the server, or connect laev and carry your keys.
      </p>
      <p :if={match?({:rate_limited, _}, @error)} class="alert alert-warning text-sm">
        You're searching a little fast — try again in {elem(@error, 1)}s.
      </p>
      <p
        :if={@error not in [nil, :no_tmdb_key] and not match?({:rate_limited, _}, @error)}
        class="alert alert-error text-sm"
      >
        Couldn't reach TMDB just now. Try again in a minute.
      </p>

      <p
        :if={@shelf.searched? and not @shelf.loading? and @shelf.items == [] and @error == nil}
        class="py-16 text-center text-base-content/60"
      >
        Nothing on TMDB matches “{@q}”.
      </p>

      <section :if={@franchises != []} class="space-y-3">
        <h2 class="text-xl font-semibold">Lists</h2>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <.list_card :for={l <- @franchises} list={l} />
        </div>
      </section>

      <section :if={@shelf.items != []} class="space-y-3">
        <h2 class="text-xl font-semibold">
          Results for “{@q}”
        </h2>
        <ul class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
          <li :for={i <- @shelf.items} class="space-y-1">
            <.poster item={i} seen={MapSet.member?(@seen, {i.type, i.id})} />
          </li>
          <li :if={@shelf.more?}>
            <button
              phx-click="more"
              disabled={@shelf.loading?}
              aria-label="More results"
              class="flex aspect-[2/3] w-full flex-col items-center justify-center gap-2 rounded-box border-2 border-dashed border-base-300 text-base-content/60 transition hover:border-primary hover:text-primary disabled:cursor-wait"
            >
              <span :if={@shelf.loading?} class="loading loading-spinner"></span>
              <.icon :if={!@shelf.loading?} name="hero-plus" class="h-8 w-8" />
              <span class="text-sm font-medium">
                {if @shelf.loading?, do: "Loading…", else: "More"}
              </span>
            </button>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
