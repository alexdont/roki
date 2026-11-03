defmodule RokiWeb.ListLive do
  @moduledoc """
  `/lists/:slug` — one franchise, start to finish, in release order: a curated
  laev list (Marvel, Star Wars …) or a TMDB collection (`collection-<id>`).

  Titles and years come from the list itself, so the page is complete at once;
  posters arrive a moment later from TMDB's cache. A connected user sees what they
  have watched greyed out, how much is left, and "Up next" on the first thing they
  have not seen. Big lists (Marvel, Animation) have tiers, chosen with `?tier=`.
  """
  use RokiWeb, :live_view

  import RokiWeb.PageHero

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Lists

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    uuid = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)

    {:ok,
     socket
     |> assign(:page_title, "List")
     |> assign(:uuid, uuid)
     |> assign(:client, RokiWeb.Client.key(socket, uuid))
     |> assign(:slug, nil)
     |> assign(:franchise, nil)
     |> assign(:tier, "all")
     |> assign(:cards, %{})
     |> assign(:seen, nil)
     |> assign(:season_posters, %{})
     |> assign(:cards_note, nil)}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _uri, socket) do
    case Lists.find(slug, socket.assigns.uuid) do
      {:ok, franchise} ->
        socket =
          socket
          |> assign(:franchise, franchise)
          |> assign(:tier, tier(franchise, params["tier"]))
          |> assign(:page_title, franchise.name)

        # Switching tier on the same list reuses what is already loaded.
        {:noreply,
         if(socket.assigns.slug == slug,
           do: socket,
           else: load(assign(socket, :slug, slug), franchise)
         )}

      :error ->
        {:noreply, socket |> put_flash(:error, "No such list.") |> push_navigate(to: ~p"/lists")}
    end
  end

  defp tier(%{tiers: tiers}, requested) do
    if requested in Enum.map(tiers, & &1.key), do: requested, else: "all"
  end

  defp load(socket, franchise) do
    if connected?(socket) do
      %{client: client, uuid: uuid, slug: slug} = socket.assigns
      entries = Lists.entries(franchise, "all")
      items = Enum.map(entries, &%{type: &1.type, id: &1.tmdb_id})

      socket
      |> assign(:cards, %{})
      |> assign(:seen, nil)
      |> assign(:season_posters, %{})
      |> assign(:cards_note, nil)
      |> start_async(:cards, fn -> Lists.cards(client, uuid, slug, entries) end)
      # An entry that is a season of a show gets that season's poster, not the show's: JoJo's list
      # is seven parts, not seven copies of the first.
      |> start_async(:season_posters, fn -> Lists.season_posters(entries, uuid) end)
      |> start_async(:seen, fn -> if uuid, do: Roki.Laev.seen_keys(uuid, items) end)
    else
      socket
    end
  end

  @impl true
  def handle_async(:cards, {:ok, {:ok, cards}}, socket),
    do: {:noreply, assign(socket, :cards, cards)}

  def handle_async(:cards, {:ok, {:error, {:rate_limited, secs}}}, socket),
    do:
      {:noreply,
       assign(socket, :cards_note, "Posters are loading slowly — try again in #{secs}s.")}

  def handle_async(:cards, {:ok, {:error, _}}, socket),
    do: {:noreply, assign(socket, :cards_note, "Couldn't load posters from TMDB just now.")}

  def handle_async(:cards, {:exit, _}, socket),
    do: {:noreply, assign(socket, :cards_note, "Couldn't load posters from TMDB just now.")}

  def handle_async(:season_posters, {:ok, %{} = posters}, socket),
    do: {:noreply, assign(socket, :season_posters, posters)}

  def handle_async(:season_posters, _other, socket), do: {:noreply, socket}

  def handle_async(:seen, {:ok, seen}, socket), do: {:noreply, assign(socket, :seen, seen)}
  def handle_async(:seen, {:exit, _}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    f = assigns.franchise
    entries = if f, do: Lists.entries(f, assigns.tier), else: []
    seen = assigns.seen

    items =
      Enum.map(entries, fn entry ->
        item = Lists.item(entry, assigns.cards)

        case assigns.season_posters[{entry.tmdb_id, entry.season}] do
          nil -> item
          poster -> %{item | poster: poster}
        end
      end)

    watched? = fn i -> seen != nil and MapSet.member?(seen, {i.type, i.id}) end
    left = if seen, do: Enum.count(items, &(not watched?.(&1))), else: nil

    up_next =
      if seen && !(f && Laev.Franchises.broad?(f)),
        do: Enum.find_index(items, &(not watched?.(&1)))

    items =
      items
      |> Enum.with_index()
      |> Enum.map(fn {i, idx} ->
        if idx == up_next, do: Map.put(i, :badge, "Up next"), else: i
      end)

    assigns =
      assign(assigns,
        items: items,
        left: left,
        watched?: watched?,
        entry_count: length(entries),
        tabs: tabs(f)
      )

    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      flush
      bleed
      overlay
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/lists"
    >
      <.page_hero
        :if={@franchise}
        eyebrow={"#{@entry_count} titles, in release order#{summary_tail(@left)}"}
        title={@franchise.name}
        hue={:erlang.phash2(@slug, 360)}
      >
        <div>
          <.link navigate={~p"/lists"} class="text-sm font-medium text-white/70 hover:text-white">
            ← All lists
          </.link>
        </div>
      </.page_hero>

      <div :if={@franchise} class={content_class()}>
        <div
          :if={@tabs != []}
          class="tabs tabs-box w-fit max-w-full flex-nowrap overflow-x-auto [scrollbar-width:none]"
          role="tablist"
        >
          <.link
            :for={t <- @tabs}
            patch={tab_path(@slug, t.key)}
            class={["tab shrink-0 whitespace-nowrap", @tier == t.key && "tab-active"]}
            title={t.blurb}
          >
            {t.label}
          </.link>
        </div>

        <p :if={@cards_note} class="alert text-sm">{@cards_note}</p>

        <div class="flex justify-end">
          <RokiWeb.GridSize.grid_switch size={@grid_size} />
        </div>

        <%!-- Watched is the greyed poster; the eye on top of it would only crowd the grid. The card
              that opens over a poster is the one Movies and Shows have (`GridCards`). --%>
        <div id="grid-cards" phx-hook="GridCards">
          <ul class={["grid gap-4", RokiWeb.GridSize.cols(@grid_size)]}>
            <RokiWeb.FeaturedLive.tile
              :for={i <- @items}
              item={i}
              kind={:list}
              seen={@watched?.(i)}
              cached_titles={@cached_titles}
              signed_in?={@uuid != nil}
            />
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Some lists carry their own "Everything" tier (Marvel's is keyed "all"); the rest
  # get one in front, so there is always a way back to the whole list.
  defp tabs(nil), do: []
  defp tabs(%{tiers: []}), do: []

  defp tabs(%{tiers: tiers}) do
    if Enum.any?(tiers, &(&1.key == "all")),
      do: tiers,
      else: [%{key: "all", label: "Everything", blurb: nil} | tiers]
  end

  defp tab_path(slug, "all"), do: ~p"/lists/#{slug}"
  defp tab_path(slug, key), do: ~p"/lists/#{slug}?#{[tier: key]}"

  defp summary_tail(nil), do: ""
  defp summary_tail(0), do: " · all watched"
  defp summary_tail(left), do: " · #{left} left"
end
