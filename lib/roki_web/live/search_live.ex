defmodule RokiWeb.SearchLive do
  @moduledoc """
  `/search?q=` — find a movie or show. Public. Results are a poster grid ending
  in a poster-sized "Load more" tile that loads the next TMDB page; above the first
  page sit any franchise lists the results belong to (a curated laev list or a
  TMDB collection). A signed-in user who has connected laev searches with their
  own TMDB key and sees what they have already watched greyed out.

  Searching is throttled — see `Roki.Search`.
  """
  use RokiWeb, :live_view

  import RokiWeb.ListComponents
  import RokiWeb.PageHero
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
     |> assign(:genre, nil)
     |> assign(:shelf, empty())
     |> assign(:place, RokiWeb.Place.from_params(socket))
     |> assign(:place_y, nil)
     |> assign(:franchises, [])
     |> assign(:seen, MapSet.new())
     |> assign(:manga, [])
     |> assign(:error, nil)}
  end

  defp empty, do: %{items: [], page: 0, more?: false, loading?: false, searched?: false}

  @impl true
  def handle_params(params, _uri, socket) do
    q = params |> Map.get("q", "") |> Roki.Search.clean()
    genre = Roki.Genres.parse(params["genre"])

    cond do
      q == socket.assigns.q and genre == socket.assigns.genre ->
        {:noreply, socket}

      String.length(q) < 2 ->
        {:noreply,
         assign(socket,
           q: q,
           genre: genre,
           shelf: empty(),
           franchises: [],
           seen: MapSet.new(),
           manga: [],
           error: nil
         )}

      true ->
        {:noreply,
         socket
         |> assign(q: q, genre: genre, franchises: [], seen: MapSet.new(), error: nil)
         |> assign(:manga, saved_manga(socket.assigns.uuid, q))
         |> take_place()
         |> fetch(1, true)}
    end
  end

  # Manga is this site's as well, and it is not on TMDB: the titles this person is already
  # reading, found from the same box. One query against our own table, so it needs no async.
  defp saved_manga(nil, _q), do: []
  defp saved_manga(uuid, q), do: Roki.Manga.Library.search_saved(uuid, q)

  # Back from a result: every page that was loaded, at once.
  defp take_place(%{assigns: %{place: %{pages: pages, y: y}}} = socket),
    do: assign(socket, place: nil, place_y: y, restore_pages: pages)

  defp take_place(socket), do: assign(socket, :restore_pages, nil)

  defp fetch(socket, page, fresh?) do
    %{q: q, genre: genre, uuid: uuid, client: client} = socket.assigns
    restore = if fresh?, do: socket.assigns[:restore_pages]
    last = restore || page

    shelf =
      if fresh?,
        do: %{empty() | loading?: true, searched?: true},
        else: %{socket.assigns.shelf | loading?: true}

    socket
    |> assign(:shelf, shelf)
    |> start_async(:search, fn ->
      if genre do
        # The page it read to is what comes back, so "Load more" carries on from there.
        case Roki.Search.search_genre(client, uuid, q, page, genre, restore) do
          {:ok, items, more?, franchises, seen, read_to} ->
            {q, genre, read_to, {:ok, items, more?, franchises, seen}}

          error ->
            {q, genre, page, error}
        end
      else
        {q, nil, last, search_pages(client, uuid, q, last)}
      end
    end)
  end

  # The media library's copy when there is one, else the source's own address through this
  # site, which carries the headers the source asks for.
  defp manga_cover(%{cover_file_uuid: uuid}) when is_binary(uuid) and uuid != "",
    do: PhoenixKit.Modules.Storage.URLSigner.signed_url(uuid, "medium")

  defp manga_cover(%{cover_url: url}) when is_binary(url) and url != "",
    do: ~p"/manga/proxy/image?#{%{url: url}}"

  defp manga_cover(_), do: nil

  # One page, or pages `1..last` joined (items in order, the franchises of the first page).
  defp search_pages(client, uuid, q, 1), do: Roki.Search.search(client, uuid, q, 1)

  defp search_pages(client, uuid, q, last) do
    results = RokiWeb.Place.pages(last, &Roki.Search.search(client, uuid, q, &1))

    case Enum.find(results, &(not match?({:ok, _, _, _, _}, &1))) do
      nil ->
        items = Enum.flat_map(results, fn {:ok, items, _, _, _} -> items end)
        {:ok, _, more?, _, _} = List.last(results)
        {:ok, _, _, franchises, _} = hd(results)

        seen =
          Enum.reduce(results, MapSet.new(), fn {:ok, _, _, _, s}, acc -> MapSet.union(acc, s) end)

        {:ok, items, more?, franchises, seen}

      error ->
        error
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, push_patch(socket, to: search_path(q, socket.assigns.genre))}

  # A genre from the menu (or none): the same search, narrowed.
  def handle_event("genre", %{"genre" => genre}, socket),
    do:
      {:noreply, push_patch(socket, to: search_path(socket.assigns.q, Roki.Genres.parse(genre)))}

  def handle_event("placed", _params, socket), do: {:noreply, assign(socket, :place_y, nil)}

  def handle_event("more", _params, socket) do
    case socket.assigns.shelf do
      %{more?: true, loading?: false, page: page} -> {:noreply, fetch(socket, page + 1, false)}
      _ -> {:noreply, socket}
    end
  end

  defp search_path(q, nil), do: ~p"/search?#{[q: q]}"
  defp search_path(q, genre), do: ~p"/search?#{[q: q, genre: genre]}"

  @impl true
  def handle_async(
        :search,
        {:ok, {q, genre, page, {:ok, items, more?, franchises, seen}}},
        %{assigns: %{q: q, genre: genre}} = socket
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

  def handle_async(
        :search,
        {:ok, {q, genre, _page, {:error, reason}}},
        %{assigns: %{q: q, genre: genre}} = socket
      ),
      do:
        {:noreply,
         assign(socket, error: reason, shelf: %{socket.assigns.shelf | loading?: false})}

  # An answer for a query the user has since replaced — success or failure.
  def handle_async(:search, {:ok, {_old_q, _old_genre, _page, _result}}, socket),
    do: {:noreply, socket}

  def handle_async(:search, {:exit, reason}, socket),
    do:
      {:noreply, assign(socket, error: reason, shelf: %{socket.assigns.shelf | loading?: false})}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      flush
      bleed
      overlay
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/search"
    >
      <.page_hero eyebrow={if @q != "", do: "Results for “#{@q}”"} title="Search" hue={24}>
        <form phx-submit="search" role="search" class="flex max-w-2xl gap-2">
          <input
            type="search"
            name="q"
            value={@q}
            placeholder="Search movies and shows — or paste an IMDb id"
            autocomplete="off"
            autofocus
            maxlength="120"
            style="background-color: rgb(0 0 0 / 0.3)"
            class="input h-12 w-full rounded-full border border-white/25 px-5 text-white backdrop-blur-md placeholder:text-white/60 focus:border-white/60 focus:outline-none"
          />
          <button type="submit" class="btn btn-primary h-12 min-h-0 rounded-full px-6">Search</button>
        </form>

        <%!-- The genre: the same search, only the titles of one. --%>
        <div :if={@q != ""} class="flex items-center gap-2">
          <div class="dropdown">
            <div
              tabindex="0"
              role="button"
              class={[
                "btn h-11 min-h-0 gap-1 rounded-full border bg-black/30 px-4 font-semibold text-white backdrop-blur-md hover:bg-black/45",
                @genre && "border-primary",
                !@genre && "border-white/25 hover:border-white/60"
              ]}
            >
              {if @genre, do: Roki.Genres.label(@genre), else: "All genres"}
              <.icon name="hero-chevron-down-micro" class="h-4 w-4" />
            </div>
            <div
              tabindex="0"
              class="dropdown-content z-40 mt-2 w-72 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
            >
              <div class="grid grid-cols-3 gap-1.5">
                <.link
                  patch={search_path(@q, nil)}
                  onclick="document.activeElement.blur()"
                  class={[
                    "btn btn-sm rounded-full border-0 px-1",
                    @genre == nil && "btn-primary",
                    @genre != nil && "bg-base-200"
                  ]}
                >
                  All
                </.link>
                <.link
                  :for={{slug, label} <- Roki.Genres.all()}
                  patch={search_path(@q, slug)}
                  onclick="document.activeElement.blur()"
                  class={[
                    "btn btn-sm rounded-full border-0 px-1 text-xs",
                    @genre == slug && "btn-primary",
                    @genre != slug && "bg-base-200"
                  ]}
                >
                  {label}
                </.link>
              </div>
            </div>
          </div>
          <.link
            :if={@genre}
            patch={search_path(@q, nil)}
            class="text-sm text-white/70 hover:text-white"
          >Clear</.link>
        </div>
      </.page_hero>

      <div class={content_class()}>
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
          Nothing on TMDB matches “{@q}”{if @genre, do: " in #{Roki.Genres.label(@genre)}"}.
        </p>

        <section :if={@franchises != []} class="space-y-3">
          <h2 class="text-xl font-semibold">Lists</h2>
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <.list_card :for={l <- @franchises} list={l} />
          </div>
        </section>

        <%!-- Manga keeps its own section rather than joining the grid: a chapter of a manhwa and
            a film are not the same kind of thing, and the sources are searched on their own
            page. --%>
        <section :if={@uuid && String.length(@q) >= 2} class="space-y-3">
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <h2 class="text-xl font-semibold">Manga</h2>
            <a href={"/manga/search?q=" <> URI.encode_www_form(@q)} class="text-sm text-primary">
              Search every source for “{@q}” →
            </a>
          </div>
          <ul
            :if={@manga != []}
            class="grid grid-cols-3 gap-3 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8"
          >
            <li :for={m <- @manga} class="space-y-1">
              <a href={~p"/manga/#{m.source}/#{m.slug}"} title={m.title}>
                <img
                  src={manga_cover(m)}
                  alt={m.title}
                  loading="lazy"
                  class="aspect-[2/3] w-full rounded-box object-cover"
                />
              </a>
            </li>
          </ul>
          <p :if={@manga == []} class="text-sm text-base-content/60">
            Nothing you are reading matches.
          </p>
        </section>

        <section :if={@shelf.items != []} class="space-y-3">
          <h2 class="text-xl font-semibold">
            Results for “{@q}”
          </h2>
          <%!-- The same grid as Movies, Shows and Anime: larger posters, whole rows while there is
              more, and "Load more" under it. --%>
          <ul
            id="grid"
            phx-hook="FillGrid"
            data-more={to_string(@shelf.more?)}
            data-page={@shelf.page}
            data-restore-y={@place_y}
            class="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6"
          >
            <li :for={i <- @shelf.items} class="space-y-1">
              <.poster
                item={i}
                seen={MapSet.member?(@seen, {i.type, i.id})}
                cached_titles={@cached_titles}
                compact
              />
            </li>
          </ul>
          <div :if={@shelf.more?} class="flex justify-center pt-4">
            <button phx-click="more" class="btn btn-wide" disabled={@shelf.loading?}>
              <span :if={@shelf.loading?} class="loading loading-spinner loading-sm"></span> Load more
            </button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
