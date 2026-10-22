defmodule RokiWeb.ListsLive do
  @moduledoc """
  `/lists` — laev's curated franchise lists, biggest first, with how much of each
  a connected user has watched. Public; the list of lists is static data, so it
  costs no TMDB request at all.
  """
  use RokiWeb, :live_view

  import RokiWeb.ListComponents

  alias PhoenixKit.Users.Auth.Scope

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    uuid = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)
    lists = Enum.map(Roki.Lists.summaries(), &Map.put(&1, :watched, nil))

    socket =
      socket
      |> assign(:page_title, "Lists")
      |> assign(:lists, lists)

    {:ok,
     if(connected?(socket) && uuid,
       do: start_async(socket, :progress, fn -> Roki.Lists.with_progress(uuid, lists) end),
       else: socket
     )}
  end

  @impl true
  def handle_async(:progress, {:ok, lists}, socket), do: {:noreply, assign(socket, :lists, lists)}
  def handle_async(:progress, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/lists"
    >
      <div class="space-y-6">
        <div class="space-y-1">
          <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Lists</h1>
          <p class="text-base-content/70">
            Curated franchises and collections, start to finish, in release order. Searching any
            title also offers the series it belongs to.
          </p>
        </div>

        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <.list_card :for={l <- @lists} list={l} />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
