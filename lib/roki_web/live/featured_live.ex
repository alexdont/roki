defmodule RokiWeb.FeaturedLive do
  @moduledoc """
  `/home` — what is popular right now: movies, shows and anime. Public; the
  same page for a visitor and a signed-in user, with the pitch on top only for
  a visitor.
  """
  use RokiWeb, :live_view

  import RokiWeb.PosterComponents

  alias PhoenixKit.Users.Auth.Scope

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Featured")
      |> assign(:state, :loading)
      |> assign(:data, nil)

    {:ok,
     if(connected?(socket),
       do: start_async(socket, :featured, &Roki.Featured.get/0),
       else: socket
     )}
  end

  @impl true
  def handle_async(:featured, {:ok, {:ok, data}}, socket),
    do: {:noreply, assign(socket, state: :ready, data: data)}

  def handle_async(:featured, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, state: {:error, reason})}

  def handle_async(:featured, {:exit, reason}, socket),
    do: {:noreply, assign(socket, state: {:error, reason})}

  @impl true
  def render(assigns) do
    scope = assigns[:phoenix_kit_current_scope]
    assigns = assign(assigns, :visitor?, !(scope && Scope.authenticated?(scope)))

    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/home"
    >
      <section :if={@visitor?} class="py-10 text-center">
        <div class="mx-auto max-w-xl space-y-4">
          <h1 class="text-4xl font-bold tracking-tight">Everything you watch, in one place.</h1>
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

      <h1 :if={!@visitor?} class="text-3xl font-bold tracking-tight">Featured</h1>

      <div
        :if={@state == :loading}
        class="flex items-center justify-center gap-3 py-24 text-base-content/60"
      >
        <span class="loading loading-spinner"></span> Loading what's popular…
      </div>

      <p :if={match?({:error, :no_tmdb_key}, @state)} class="alert text-sm">
        Featured needs a TMDB key — set <code>TMDB_API_KEY</code> on the server.
      </p>
      <p :if={match?({:error, r} when r != :no_tmdb_key, @state)} class="alert alert-error text-sm">
        Couldn't reach TMDB just now. Try again in a minute.
      </p>

      <div :if={@state == :ready} class="space-y-10">
        <.shelf title="Trending movies" items={@data.movies} />
        <.shelf title="Trending shows" items={@data.shows} />
        <.shelf title="Anime airing now" items={@data.anime} />
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, required: true

  defp shelf(assigns) do
    ~H"""
    <section :if={@items != []} class="space-y-3">
      <h2 class="text-xl font-semibold">{@title}</h2>
      <ul class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
        <li :for={i <- Enum.take(@items, 16)} class="space-y-1">
          <.poster item={i} />
        </li>
      </ul>
    </section>
    """
  end
end
