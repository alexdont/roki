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

  import RokiWeb.PosterComponents

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
      |> assign(:cards_note, nil)
      |> start_async(:cards, fn -> Lists.cards(client, uuid, slug, entries) end)
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

  def handle_async(:seen, {:ok, seen}, socket), do: {:noreply, assign(socket, :seen, seen)}
  def handle_async(:seen, {:exit, _}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    f = assigns.franchise
    entries = if f, do: Lists.entries(f, assigns.tier), else: []
    seen = assigns.seen
    items = Enum.map(entries, &Lists.item(&1, assigns.cards))
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
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/lists"
    >
      <div :if={@franchise} class="space-y-6">
        <div class="space-y-1">
          <.link navigate={~p"/lists"} class="text-sm text-base-content/60 hover:text-primary">
            ← All lists
          </.link>
          <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">🎬 {@franchise.name}</h1>
          <p class="text-base-content/70">
            {@entry_count} titles, in release order{summary_tail(@left)}
          </p>
        </div>

        <div :if={@tabs != []} class="tabs tabs-box w-fit max-w-full overflow-x-auto" role="tablist">
          <.link
            :for={t <- @tabs}
            patch={tab_path(@slug, t.key)}
            class={["tab", @tier == t.key && "tab-active"]}
            title={t.blurb}
          >
            {t.label}
          </.link>
        </div>

        <p :if={@cards_note} class="alert text-sm">{@cards_note}</p>

        <ul class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
          <li :for={i <- @items} class="space-y-1">
            <.poster item={i} seen={@watched?.(i)} cached_titles={@cached_titles} />
          </li>
        </ul>
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
