defmodule RokiWeb.MangaLive do
  @moduledoc """
  The manga shelf and a series' chapters. The reading itself belongs to the packaged reader
  (`/manga/:source/:slug/:chapter`, a plain controller page); these two are the way in and out of
  it — what you have saved, where you were, and which chapter to open next.
  """
  use RokiWeb, :live_view

  alias Roki.Manga.{Library, Sources, Store}

  @impl true
  def mount(_params, _session, socket) do
    case PhoenixKit.Users.Auth.Scope.user(socket.assigns[:phoenix_kit_current_scope]) do
      nil ->
        {:ok, redirect(socket, to: PhoenixKit.Utils.Routes.path("/users/log-in"))}

      user ->
        {:ok, assign(socket, user: user, chapters: [], state: nil, series: nil, loading: false)}
    end
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: :series}} = socket) do
    %{"source" => source, "slug" => slug} = params
    user = socket.assigns.user

    socket =
      assign(socket,
        source: source,
        slug: slug,
        state: Library.state(user.uuid, source, slug),
        series: Library.series(Library.series_id(source, slug)),
        loading: true
      )

    # The chapter list means asking the source, which can take seconds — the page draws first.
    {:noreply,
     start_async(socket, :chapters, fn -> Store.list_chapters(user, [source, slug]) end)}
  end

  def handle_params(params, _uri, socket) do
    uuid = socket.assigns.user.uuid

    category =
      with s when is_binary(s) <- params["category"],
           {n, ""} <- Integer.parse(s),
           do: n,
           else: (_ -> nil)

    {:noreply,
     assign(socket,
       home: Library.home(uuid, category),
       categories: Library.categories(uuid),
       category: category
     )}
  end

  @impl true
  def handle_async(:chapters, {:ok, chapters}, socket),
    do: {:noreply, assign(socket, chapters: chapters, loading: false)}

  def handle_async(:chapters, _other, socket), do: {:noreply, assign(socket, loading: false)}

  # A cover sits on the source's own CDN, which refuses a request that did not come from the
  # site it serves — so it goes through the reader's image proxy, which puts the referer back on.
  # Anything already local (a stored file, the sidecar) is left alone.
  defp cover("/" <> _ = url), do: url

  defp cover(url) do
    if Roki.Manga.Sidecar.image_url?(url),
      do: Roki.Manga.Sidecar.rehost(url),
      else: "/manga/proxy/image?" <> URI.encode_query(url: url)
  end

  @impl true
  def render(%{live_action: :series} = assigns) do
    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/manga"
    >
      <div class="space-y-4">
        <.link navigate={~p"/manga"} class="text-sm text-base-content/60 hover:text-base-content">
          ← Shelf
        </.link>

        <div class="flex flex-wrap items-end gap-4">
          <h1 class="font-display text-2xl font-bold">
            {(@series && @series.title) || @slug}
          </h1>
          <span class="badge badge-ghost">{Sources.label(@source)}</span>
        </div>

        <p :if={@state && @state.last_chapter} class="text-sm text-base-content/70">
          You were on chapter {@state.last_chapter}.
        </p>

        <div :if={@loading} class="flex items-center gap-2 text-sm text-base-content/60">
          <span class="loading loading-spinner loading-sm"></span> Asking {Sources.label(@source)}…
        </div>

        <p :if={not @loading and @chapters == []} class="text-sm text-base-content/60">
          No chapters came back. The source may be down, or this series may have moved.
        </p>

        <ul :if={@chapters != []} class="flex flex-wrap gap-2">
          <li :for={chapter <- @chapters}>
            <.link
              href={~p"/manga/#{@source}/#{@slug}/#{chapter}"}
              class={[
                "btn btn-sm",
                if(@state && @state.last_chapter == chapter, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              {chapter}
            </.link>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/manga"
    >
      <div class="space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="font-display text-2xl font-bold">Manga</h1>
          <span class="text-sm text-base-content/60">{@home.count} on your shelf</span>
        </div>

        <div :if={@categories != []} class="flex flex-wrap gap-2">
          <.link
            patch={~p"/manga"}
            class={["btn btn-xs", if(is_nil(@category), do: "btn-primary", else: "btn-ghost")]}
          >
            Everything
          </.link>
          <.link
            :for={c <- @categories}
            patch={~p"/manga?#{[category: c.id]}"}
            class={["btn btn-xs", if(@category == c.id, do: "btn-primary", else: "btn-ghost")]}
          >
            {c.name}
          </.link>
        </div>

        <p :if={@home.count == 0} class="text-sm text-base-content/60">Nothing here yet.</p>

        <.section title="Continue reading" items={@home.reading} />
        <.section title="Caught up" items={@home.caught_up} />
        <.section title="Not started" items={@home.unread} />
        <.section title="Finished" items={@home.completed} />
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, required: true

  defp section(assigns) do
    ~H"""
    <section :if={@items != []} class="space-y-2">
      <h2 class="font-display text-lg font-semibold">
        {@title} <span class="text-sm font-normal text-base-content/50">{length(@items)}</span>
      </h2>

      <ul class="grid grid-cols-3 gap-3 sm:grid-cols-4 lg:grid-cols-6">
        <li :for={item <- @items} class="poster-card overflow-hidden rounded-box bg-base-200">
          <.link navigate={~p"/manga/#{item.source}/#{item.slug}"} class="block">
            <img
              :if={item.cover_url}
              src={cover(item.cover_url)}
              alt=""
              loading="lazy"
              class="aspect-[2/3] w-full object-cover"
            />
            <div
              :if={is_nil(item.cover_url)}
              class="flex aspect-[2/3] w-full items-center justify-center bg-base-300 text-xs text-base-content/40"
            >
              no cover
            </div>
            <div class="space-y-1 p-2">
              <p class="line-clamp-2 text-sm font-medium">{item.title}</p>
              <p class="text-xs text-base-content/60">
                <span :if={item.last_chapter}>ch. {item.last_chapter}</span>
                <span :if={is_nil(item.last_chapter)}>not started</span>
                <span :if={item.total_chapters}>/ {item.total_chapters}</span>
              </p>
            </div>
          </.link>
        </li>
      </ul>
    </section>
    """
  end
end
