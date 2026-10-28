defmodule RokiWeb.MangaLive do
  @moduledoc """
  The manga shelf and a series' page. The reading itself belongs to the packaged reader
  (`/manga/:source/:slug/:chapter`, a plain controller page); these two are the way in and out of
  it, arranged the way the old reader arranged them — what you are part-way through across the
  top, a filter for the rest, and a series page that opens on where you left off.
  """
  use RokiWeb, :live_view

  alias Roki.Manga.{Library, Sidecar, Sources, Store}

  @filters [
    {:all, "All"},
    {:reading, "Reading"},
    {:caught_up, "Caught up"},
    {:unread, "Unread"},
    {:completed, "Finished"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    case PhoenixKit.Users.Auth.Scope.user(socket.assigns[:phoenix_kit_current_scope]) do
      nil ->
        {:ok, redirect(socket, to: PhoenixKit.Utils.Routes.path("/users/log-in"))}

      user ->
        {:ok, assign(socket, user: user, chapters: [], loading: false, details: nil)}
    end
  end

  @impl true
  def handle_params(
        %{"source" => source, "slug" => slug},
        _uri,
        %{assigns: %{live_action: :series}} = socket
      ) do
    user = socket.assigns.user

    socket =
      assign(socket,
        source: source,
        slug: slug,
        details: Library.details(user.uuid, source, slug),
        loading: true,
        chapters: []
      )

    # Asking the source for its chapter list takes seconds, so the page draws first.
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

    filter = Enum.find_value(@filters, :all, fn {k, _} -> to_string(k) == params["show"] && k end)

    {:noreply,
     assign(socket,
       home: Library.home(uuid, category),
       categories: Library.categories(uuid),
       category: category,
       filter: filter
     )}
  end

  @impl true
  def handle_async(:chapters, {:ok, chapters}, socket),
    do: {:noreply, assign(socket, chapters: chapters, loading: false)}

  def handle_async(:chapters, _other, socket), do: {:noreply, assign(socket, loading: false)}

  @impl true
  def handle_event(
        "unsave",
        _params,
        %{assigns: %{source: source, slug: slug, user: user}} = socket
      ) do
    Library.unsave(user.uuid, source, slug)
    {:noreply, push_navigate(socket, to: ~p"/manga")}
  end

  def handle_event(
        "save",
        _params,
        %{assigns: %{source: source, slug: slug, user: user}} = socket
      ) do
    Library.save(user.uuid, source, slug)
    {:noreply, assign(socket, details: Library.details(user.uuid, source, slug))}
  end

  # ── the series ───────────────────────────────────────────────────────

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
      <div class="space-y-6">
        <.link navigate={~p"/manga"} class="text-sm text-base-content/60 hover:text-base-content">
          ← Shelf
        </.link>

        <div class="flex flex-col gap-5 sm:flex-row">
          <img
            :if={cover_of(@details)}
            src={cover(cover_of(@details))}
            alt=""
            class="w-36 shrink-0 rounded-box object-cover shadow-lg sm:w-48"
          />

          <div class="min-w-0 flex-1 space-y-3">
            <div class="space-y-1">
              <h1 class="font-display text-2xl font-bold">{title_of(@details, @slug)}</h1>
              <p class="flex flex-wrap items-center gap-2 text-sm text-base-content/60">
                <span class="badge badge-ghost">{Sources.label(@source)}</span>
                <span :if={@details.saved && @details.saved.total_chapters}>
                  {@details.saved.total_chapters} chapters
                </span>
                <span :if={@details.saved && @details.saved.reading_seconds > 0}>
                  {spent(@details.saved.reading_seconds)} read
                </span>
                <span :for={shelf <- @details.shelves} class="badge badge-outline badge-sm">
                  {shelf}
                </span>
              </p>
            </div>

            <p :if={synopsis(@details)} class="max-w-prose text-sm text-base-content/80">
              {synopsis(@details)}
            </p>

            <div class="flex flex-wrap gap-2 pt-1">
              <.link
                :if={continue_at(@details, @chapters)}
                href={~p"/manga/#{@source}/#{@slug}/#{continue_at(@details, @chapters)}"}
                class="btn btn-primary"
              >
                {if @details.saved && @details.saved.last_chapter, do: "Continue", else: "Start"} ch. {continue_at(
                  @details,
                  @chapters
                )}
              </.link>

              <button :if={@details.saved} type="button" phx-click="unsave" class="btn btn-ghost">
                Remove from shelf
              </button>
              <button :if={is_nil(@details.saved)} type="button" phx-click="save" class="btn">
                Add to shelf
              </button>
            </div>

            <p
              :if={@details.saved && @details.saved.last_chapter}
              class="text-sm text-base-content/60"
            >
              You were on chapter {@details.saved.last_chapter}<span :if={
                @details.saved.max_chapter &&
                  @details.saved.max_chapter != @details.saved.last_chapter
              }>, furthest {@details.saved.max_chapter}</span>.
            </p>
          </div>
        </div>

        <div class="space-y-2">
          <h2 class="font-display text-lg font-semibold">
            Chapters
            <span :if={@chapters != []} class="text-sm font-normal text-base-content/50">{length(
              @chapters
            )}</span>
          </h2>

          <div :if={@loading} class="flex items-center gap-2 text-sm text-base-content/60">
            <span class="loading loading-spinner loading-sm"></span> Asking {Sources.label(@source)}…
          </div>

          <p :if={not @loading and @chapters == []} class="text-sm text-base-content/60">
            No chapters came back. The source may be down, or this series may have moved.
          </p>

          <ul :if={@chapters != []} class="flex flex-wrap gap-1.5">
            <li :for={chapter <- @chapters}>
              <.link
                href={~p"/manga/#{@source}/#{@slug}/#{chapter}"}
                class={[
                  "btn btn-sm",
                  cond do
                    @details.saved && @details.saved.last_chapter == chapter -> "btn-primary"
                    MapSet.member?(@details.read, chapter) -> "btn-ghost opacity-50"
                    true -> "btn-ghost"
                  end
                ]}
              >
                {chapter}
              </.link>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── the shelf ────────────────────────────────────────────────────────

  def render(assigns) do
    assigns = assign(assigns, filters: @filters, shown: shown(assigns.home, assigns.filter))

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

        <%!-- What you are in the middle of, always in front — the reader's own first row. --%>
        <section :if={@home.reading != [] and @filter == :all} class="space-y-2">
          <h2 class="font-display text-lg font-semibold">
            Continue reading
            <span class="text-sm font-normal text-base-content/50">{length(@home.reading)}</span>
          </h2>
          <ul class="grid grid-cols-3 gap-3 sm:grid-cols-4 lg:grid-cols-6">
            <.tile :for={item <- Enum.take(@home.reading, 12)} item={item} />
          </ul>
        </section>

        <div class="flex flex-wrap items-center gap-2">
          <.link
            :for={{key, label} <- @filters}
            patch={filter_path(key, @category)}
            class={["btn btn-xs", if(@filter == key, do: "btn-primary", else: "btn-ghost")]}
          >
            {label}
            <span :if={key != :all} class="opacity-60">{count_of(@home, key)}</span>
          </.link>

          <span :if={@categories != []} class="mx-1 h-4 w-px bg-base-300"></span>

          <.link
            :for={c <- @categories}
            patch={category_path(@filter, if(@category == c.id, do: nil, else: c.id))}
            class={["btn btn-xs", if(@category == c.id, do: "btn-secondary", else: "btn-ghost")]}
          >
            {c.name}
          </.link>
        </div>

        <p :if={@shown == []} class="text-sm text-base-content/60">Nothing here.</p>

        <ul :if={@shown != []} class="grid grid-cols-3 gap-3 sm:grid-cols-4 lg:grid-cols-6">
          <.tile :for={item <- @shown} item={item} />
        </ul>
      </div>
    </Layouts.app>
    """
  end

  attr :item, :map, required: true

  defp tile(assigns) do
    ~H"""
    <li class="poster-card overflow-hidden rounded-box bg-base-200">
      <.link navigate={~p"/manga/#{@item.source}/#{@item.slug}"} class="block">
        <img
          :if={@item.cover_url}
          src={cover(@item.cover_url)}
          alt=""
          loading="lazy"
          class="aspect-[2/3] w-full object-cover"
        />
        <div
          :if={is_nil(@item.cover_url)}
          class="flex aspect-[2/3] w-full items-center justify-center bg-base-300 text-xs text-base-content/40"
        >
          no cover
        </div>
        <div class="space-y-1 p-2">
          <p class="line-clamp-2 text-sm font-medium">{@item.title}</p>
          <p class="text-xs text-base-content/60">
            <span :if={@item.last_chapter}>ch. {@item.last_chapter}</span>
            <span :if={is_nil(@item.last_chapter)}>not started</span>
            <span :if={@item.total_chapters}>/ {@item.total_chapters}</span>
          </p>
        </div>
      </.link>
    </li>
    """
  end

  # ── the small decisions ──────────────────────────────────────────────

  defp shown(home, :all), do: home.reading ++ home.caught_up ++ home.unread ++ home.completed
  defp shown(home, :reading), do: home.reading
  defp shown(home, :caught_up), do: home.caught_up
  defp shown(home, :unread), do: home.unread
  defp shown(home, :completed), do: home.completed

  defp count_of(home, key), do: home |> shown(key) |> length()

  defp filter_path(:all, nil), do: ~p"/manga"
  defp filter_path(:all, category), do: ~p"/manga?#{[category: category]}"
  defp filter_path(key, nil), do: ~p"/manga?#{[show: key]}"
  defp filter_path(key, category), do: ~p"/manga?#{[show: key, category: category]}"

  defp category_path(filter, category), do: filter_path(filter, category)

  defp title_of(%{series: %{title: t}}, _slug) when is_binary(t) and t != "", do: t
  defp title_of(%{saved: %{title: t}}, _slug) when is_binary(t) and t != "", do: t
  defp title_of(_, slug), do: slug

  defp cover_of(%{saved: %{cover_url: c}}) when is_binary(c) and c != "", do: c
  defp cover_of(%{series: %{cover_url: c}}) when is_binary(c) and c != "", do: c
  defp cover_of(_), do: nil

  defp synopsis(%{series: %{data: %{"synopsis" => s}}}) when is_binary(s) and s != "", do: s
  defp synopsis(_), do: nil

  # Where the Continue button goes: where they were, else the first chapter there is.
  defp continue_at(%{saved: %{last_chapter: c}}, _chapters) when is_binary(c) and c != "", do: c
  defp continue_at(_details, [first | _]), do: first
  defp continue_at(_details, _), do: nil

  defp spent(seconds) when seconds >= 3600,
    do: "#{div(seconds, 3600)} h #{div(rem(seconds, 3600), 60)} m"

  defp spent(seconds), do: "#{div(seconds, 60)} m"

  # A cover sits on the source's own CDN, which refuses a request that did not come from the site
  # it serves — so it goes through the reader's image proxy, which puts the referer back on.
  defp cover("/" <> _ = url), do: url

  defp cover(url) do
    if Sidecar.image_url?(url),
      do: Sidecar.rehost(url),
      else: "/manga/proxy/image?" <> URI.encode_query(url: url)
  end
end
