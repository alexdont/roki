defmodule RokiWeb.PersonLive do
  @moduledoc """
  `/person/:id` — an actor, and every film and show they played in, as a poster grid: the page
  a face in a title's cast row leads to. Public. Movies and shows can be shown apart (`?kind=`),
  and the grid takes the device's poster size like every other grid.
  """
  use RokiWeb, :live_view

  import RokiWeb.PageHero

  alias PhoenixKit.Users.Auth.Scope

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    uuid = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)

    {:ok,
     socket
     |> assign(:page_title, "Actor")
     |> assign(:uuid, uuid)
     |> assign(:id, nil)
     |> assign(:person, nil)
     |> assign(:cards, [])
     |> assign(:seen, MapSet.new())
     |> assign(:kind, nil)
     |> assign(:loading?, true)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    kind = if params["kind"] in ["movie", "tv"], do: params["kind"]

    case Integer.parse(id) do
      {id, ""} when id > 0 and id != socket.assigns.id ->
        uuid = socket.assigns.uuid

        {:noreply,
         socket
         |> assign(id: id, kind: kind, loading?: true, error: nil)
         |> start_async(:person, fn ->
           with {:ok, person} <- Roki.People.for_person(uuid, id) do
             {:ok, person, Roki.Laev.annotate(uuid, person.cards),
              Roki.Laev.seen_keys(uuid, person.cards)}
           end
         end)}

      {_id, ""} ->
        {:noreply, assign(socket, :kind, kind)}

      _ ->
        {:noreply, assign(socket, loading?: false, error: :not_found)}
    end
  end

  @impl true
  def handle_async(:person, {:ok, {:ok, person, cards, seen}}, socket) do
    {:noreply,
     assign(socket,
       person: person,
       cards: cards,
       seen: seen,
       loading?: false,
       page_title: person.name
     )}
  end

  def handle_async(:person, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, loading?: false, error: reason)}

  def handle_async(:person, {:exit, reason}, socket),
    do: {:noreply, assign(socket, loading?: false, error: reason)}

  defp shown(cards, nil), do: cards
  defp shown(cards, kind), do: Enum.filter(cards, &(&1.type == kind))

  defp person_path(id, nil), do: ~p"/person/#{id}"
  defp person_path(id, kind), do: ~p"/person/#{id}?#{[kind: kind]}"

  @impl true
  def render(assigns) do
    shown = shown(assigns.cards, assigns.kind)
    # Where you know them from: the ones of these you have watched, with the part they played.
    known = Enum.filter(shown, &MapSet.member?(assigns.seen, {&1.type, &1.id}))
    assigns = assign(assigns, shown: shown, known: known)

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
      <.page_hero
        eyebrow={if @person, do: "Films and shows with"}
        title={(@person && @person.name) || "Actor"}
        hue={262}
      >
        <div :if={@person} class="flex flex-wrap items-center gap-3">
          <div
            :if={@person.photo}
            class="h-16 w-16 overflow-hidden rounded-full ring-2 ring-white/40"
          >
            <img
              src={Roki.Images.local(@person.photo)}
              alt=""
              class="h-full w-full object-cover"
            />
          </div>
          <div class="join rounded-full">
            <.link
              :for={{k, label} <- [{nil, "All"}, {"movie", "Movies"}, {"tv", "Shows"}]}
              patch={person_path(@id, k)}
              class={[
                "btn join-item h-10 min-h-0 border-white/25 px-4 font-semibold",
                @kind == k && "btn-primary border-primary",
                @kind != k && "bg-black/30 text-white backdrop-blur-md hover:bg-black/45"
              ]}
            >
              {label}
            </.link>
          </div>
        </div>
      </.page_hero>

      <div class={content_class()}>
        <div :if={@loading?} class="flex justify-center gap-3 py-24 text-base-content/60">
          <span class="loading loading-spinner"></span> Looking them up…
        </div>

        <p :if={@error == :not_found} class="py-16 text-center text-base-content/60">
          TMDB has no one by that id.
        </p>
        <p :if={@error == :no_tmdb_key} class="alert text-sm">
          This page needs a TMDB key — set <code>TMDB_API_KEY</code> on the server.
        </p>
        <p :if={@error not in [nil, :not_found, :no_tmdb_key]} class="alert alert-error text-sm">
          Couldn't reach TMDB just now. Try again in a minute.
        </p>

        <p
          :if={@person && @shown == []}
          class="py-16 text-center text-base-content/60"
        >
          Nothing on TMDB has {@person.name} in it{if @kind == "movie",
            do: " as a film",
            else: if(@kind == "tv", do: " as a show", else: "")}.
        </p>

        <section :if={@known != []} class="space-y-3" aria-label="You know them from">
          <div>
            <h2 class="text-xl font-semibold">You know them from</h2>
            <p class="text-sm text-base-content/60">
              What you have watched with {@person.name} in it, and who they were.
            </p>
          </div>
          <%!-- Not greyed as watched here: these are the ones you know. The card that opens over a
               poster is the same as below. --%>
          <div id="grid-known-cards" phx-hook="GridCards">
            <ul id="grid-known" class={["grid gap-4", RokiWeb.GridSize.cols(@grid_size, "m")]}>
              <RokiWeb.FeaturedLive.tile
                :for={i <- @known}
                item={i}
                kind={:search}
                cached_titles={@cached_titles}
                friends_seen={@friends_seen}
                signed_in?={@uuid != nil}
              >
                <p class="mt-1 truncate text-sm font-medium" title={i.title}>{i.title}</p>
                <p
                  :if={i[:character]}
                  class="truncate text-xs text-base-content/60"
                  title={i.character}
                >
                  as {i.character}
                </p>
              </RokiWeb.FeaturedLive.tile>
            </ul>
          </div>
        </section>

        <section :if={@shown != []} class="space-y-3">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-xl font-semibold">
              {length(@shown)} {cond do
                @kind == "movie" -> "films"
                @kind == "tv" -> "shows"
                true -> "titles"
              end}, newest first
            </h2>
            <RokiWeb.GridSize.grid_switch size={@grid_size} default="m" />
          </div>
          <div id="grid-cards" phx-hook="GridCards">
            <ul
              id="grid"
              phx-hook="FillGrid"
              data-more="false"
              data-page="1"
              class={["grid gap-4", RokiWeb.GridSize.cols(@grid_size, "m")]}
            >
              <RokiWeb.FeaturedLive.tile
                :for={i <- @shown}
                item={i}
                kind={:search}
                seen={MapSet.member?(@seen, {i.type, i.id})}
                cached_titles={@cached_titles}
                friends_seen={@friends_seen}
                signed_in?={@uuid != nil}
              />
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
