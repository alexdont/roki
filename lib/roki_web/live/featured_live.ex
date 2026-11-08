defmodule RokiWeb.FeaturedLive do
  @moduledoc """
  `/home` — what is popular right now: movies, shows and anime. Public; the
  same page for a visitor and a signed-in user, with the pitch on top only for
  a visitor. Each shelf ends in a poster-sized "Load more" tile that loads the next
  TMDB page, like laev's Featured screen. A signed-in user who has connected
  laev sees what they have already watched greyed out.
  """
  use RokiWeb, :live_view

  import RokiWeb.PosterComponents

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Featured

  # The Lists row draws six to begin with and six more each time it is scrolled to its end (or the
  # chevron is pressed); the rest are on the Lists page.
  @lists_first 6
  @lists_chunk 6
  @page_size 20

  @titles %{movies: "Trending movies", shows: "Trending shows", anime: "Anime airing now"}

  @impl true
  def mount(_params, _session, socket) do
    shelf = %{items: [], page: 0, more?: false, loading?: true}

    shelves =
      Featured.kinds()
      |> Map.new(&{&1, shelf})
      # The Seasonal row: what suits the time of year (`Roki.Seasonal`), twenty titles like the rest.
      |> Map.put(:seasonal, shelf)

    socket =
      socket
      |> assign(:page_title, "Featured")
      |> assign(:shelves, shelves)
      |> assign(:season, Roki.Seasonal.current())
      |> assign(:error, nil)
      |> assign(:seen, MapSet.new())
      |> assign(:upcoming, %{})
      |> assign(:uuid, uuid(socket))
      |> assign(:activity, if(uuid(socket), do: nil, else: []))
      |> assign(activity_kind: nil, activity_who: :all, activity_open: nil, now: [])
      |> assign(:lists, Enum.map(Roki.Lists.summaries(), &Map.put(&1, :watched, nil)))
      # The mood picker: what is held already is drawn in the first render, the rest arrives.
      |> assign(:moods, Roki.Mood.hero_peek())
      # Which mood the carousel opens on: a random one, the tabs keep their order. The first paint
      # picks it and the browser hands it back on connect (`mood` param), so it does not change.
      |> assign(:mood_start, mood_start(socket))
      # Each mood's animation over the carousel (mood_fx.js); a site-wide switch.
      |> assign(:mood_fx?, Application.get_env(:roki, :mood_fx, true))
      |> assign(:list_posters, %{})
      |> assign(:lists_shown, @lists_first)

    {:ok, if(connected?(socket), do: start(socket), else: socket)}
  end

  defp mood_start(socket) do
    slugs = Enum.map(Roki.Mood.all(), & &1.slug)
    held = connected?(socket) && get_connect_params(socket)["mood"]
    if held in slugs, do: held, else: Enum.random(slugs)
  end

  # Who finished what, newest first. Only for people signed in (it names other people); it stays
  # up to date: a finish anywhere tells every open page.
  defp load_activity(socket) do
    %{uuid: uuid, activity_kind: kind, activity_who: who} = socket.assigns

    if uuid do
      opts =
        [kinds: kind && [kind]] ++
          case who do
            :mine -> [users: [uuid]]
            :friends -> [users: Enum.map(Roki.Social.friends(uuid), & &1.uuid)]
            _ -> []
          end

      start_async(socket, :activity, fn ->
        Roki.Activity.recent(60, Enum.reject(opts, &match?({_, nil}, &1)))
      end)
    else
      socket
    end
  end

  # Who is in the player right now (`Roki.NowWatching`), narrowed by the same "whose" switch as
  # the rest of the row; hidden when the row is narrowed to a kind that is not "started".
  defp load_now(%{assigns: %{uuid: uuid, activity_kind: kind, activity_who: who}} = socket)
       when is_binary(uuid) do
    friends = if who == :friends, do: MapSet.new(Roki.Social.friends(uuid), & &1.uuid)

    now =
      if kind in [nil, "started"] do
        Enum.filter(Roki.NowWatching.list(), fn e ->
          case who do
            :mine -> e.user == uuid
            :friends -> MapSet.member?(friends, e.user)
            _ -> true
          end
        end)
      else
        []
      end

    assign(socket, :now, now)
  end

  defp load_now(socket), do: socket

  @impl true
  def handle_event("activity_kind", %{"kind" => kind}, socket) do
    kind = if kind in Roki.Activity.kinds(), do: kind

    {:noreply,
     socket |> assign(activity_kind: kind, activity_open: nil) |> load_activity() |> load_now()}
  end

  def handle_event("activity_who", %{"who" => who}, socket) do
    who = Enum.find([:all, :friends, :mine], :all, &(Atom.to_string(&1) == who))

    {:noreply,
     socket |> assign(activity_who: who, activity_open: nil) |> load_activity() |> load_now()}
  end

  # A group of titles opens as a list of them.
  def handle_event("activity_open", %{"i" => i}, socket) do
    run =
      with {n, ""} <- Integer.parse(i),
           list when is_list(list) <- socket.assigns.activity,
           do: Enum.at(list, n)

    {:noreply, assign(socket, :activity_open, if(is_map(run) and run.batch?, do: run))}
  end

  def handle_event("activity_close", _params, socket),
    do: {:noreply, assign(socket, :activity_open, nil)}

  # The Lists row has been scrolled to its end: draw the next few, with their posters.
  def handle_event("row_more", %{"kind" => "lists"}, socket) do
    %{lists: lists, lists_shown: shown} = socket.assigns
    total = length(lists)

    if shown >= total do
      {:noreply, socket}
    else
      next = min(shown + @lists_chunk, total)
      fresh = Enum.slice(lists, shown, next - shown)

      {:noreply,
       socket
       |> assign(:lists_shown, next)
       |> start_async({:list_posters, shown}, fn -> Roki.Lists.previews(fresh) end)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:activity, socket), do: {:noreply, load_activity(socket)}
  def handle_info(:now_watching, socket), do: {:noreply, load_now(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  defp start(socket) do
    %{uuid: uuid, lists: lists} = socket.assigns
    socket = Enum.reduce(Featured.kinds(), socket, &fetch(&2, &1, 1))
    socket = fetch_seasonal(socket)

    if uuid do
      Phoenix.PubSub.subscribe(Roki.PubSub, Roki.Activity.topic())
      Phoenix.PubSub.subscribe(Roki.PubSub, Roki.NowWatching.topic())
    end

    socket = socket |> load_activity() |> load_now()
    socket = start_async(socket, :moods, fn -> Roki.Mood.hero(uuid) end)

    socket =
      start_async(socket, :list_posters, fn ->
        Roki.Lists.previews(Enum.take(lists, @lists_first))
      end)

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

  # The Seasonal row: the first page of the season's titles (films and shows mixed), cut to twenty.
  defp fetch_seasonal(socket) do
    %{uuid: uuid, season: season} = socket.assigns

    start_async(socket, :seasonal, fn ->
      case Roki.Mood.page(season.slug, :all, :popular, 1, uuid) do
        {:ok, items, _more?} ->
          items = Enum.take(items, @page_size)
          {:ok, Roki.Laev.annotate(uuid, items), Roki.Laev.seen_keys(uuid, items)}

        error ->
          error
      end
    end)
  end

  @impl true
  def handle_async(:seasonal, {:ok, {:ok, items, seen}}, socket) do
    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(:seen, MapSet.union(socket.assigns.seen, seen))
     |> start_async({:dates, :seasonal, 1}, fn -> Roki.Watch.upcoming(uuid, items) end)
     |> put_shelf(:seasonal, %{socket.assigns.shelves.seasonal | items: items, loading?: false})}
  end

  # No page-wide error for it: the row is simply not drawn when it has nothing to show.
  def handle_async(:seasonal, _other, socket),
    do:
      {:noreply,
       put_shelf(socket, :seasonal, %{socket.assigns.shelves.seasonal | loading?: false})}

  def handle_async({:page, kind}, {:ok, {page, {:ok, items, more?}, seen}}, socket) do
    shelf = socket.assigns.shelves[kind]
    known = MapSet.new(shelf.items, & &1.id)
    fresh = Enum.reject(items, &MapSet.member?(known, &1.id))
    uuid = socket.assigns.uuid

    # Every title not asked about yet, not only the new ones (what was drawn from the cache first is
    # not new, and would never get its "not out yet" mark).
    asked = Map.keys(socket.assigns.upcoming)
    unasked = Enum.reject(items, &({&1[:type], &1.id} in asked))

    {:noreply,
     socket
     |> assign(:seen, MapSet.union(socket.assigns.seen, seen))
     |> start_async({:dates, kind, page}, fn -> Roki.Watch.upcoming(uuid, unasked) end)
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

  def handle_async(:moods, {:ok, %{} = moods}, socket),
    do: {:noreply, assign(socket, :moods, Map.merge(socket.assigns.moods, moods))}

  def handle_async(:moods, _other, socket), do: {:noreply, socket}

  def handle_async(name, {:ok, %{} = posters}, socket)
      when name == :list_posters or (is_tuple(name) and elem(name, 0) == :list_posters),
      do:
        {:noreply, assign(socket, :list_posters, Map.merge(socket.assigns.list_posters, posters))}

  def handle_async(name, _other, socket)
      when name == :list_posters or (is_tuple(name) and elem(name, 0) == :list_posters),
      do: {:noreply, socket}

  # (A filter change keeps the old list on screen until the new one is in.)

  def handle_async(:activity, _other, socket), do: {:noreply, socket}

  def handle_async(:progress, {:ok, lists}, socket), do: {:noreply, assign(socket, :lists, lists)}
  def handle_async(:progress, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async({:page, kind}, {:exit, reason}, socket),
    do: {:noreply, failed(socket, kind, reason)}

  attr :e, :map, required: true

  # Someone in the player this moment: a green dot that pulses while it plays (a still amber one
  # when it is paused but open), how far in, and the title. Leads the row; the finished/started
  # cards follow it.
  defp now_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/title/#{@e.what.type}/#{@e.what.tmdb_id}"}
      class={[
        "group flex w-64 shrink-0 snap-start items-center gap-3 rounded-box border bg-base-100 p-2.5 transition hover:bg-base-200 sm:w-72",
        (@e.paused? && "border-base-300") || "border-success/50"
      ]}
    >
      <.activity_poster poster={@e.what.poster} class="h-16 w-11 shrink-0" />
      <div class="min-w-0 flex-1 text-sm leading-snug">
        <p class="line-clamp-2">
          <span class="font-semibold">{@e.username}</span>
          <span class="text-base-content/70">{if @e.paused?, do: "paused", else: "is watching"}</span>
          <span class="font-semibold">{now_title(@e.what)}</span>
        </p>
        <p class="mt-0.5 flex items-center gap-1.5 text-xs text-base-content/60">
          <span class="relative flex h-2.5 w-2.5 shrink-0" aria-hidden="true">
            <span
              :if={!@e.paused?}
              class="absolute inline-flex h-full w-full animate-ping rounded-full bg-success opacity-75"
            ></span>
            <span class={[
              "relative inline-flex h-2.5 w-2.5 rounded-full",
              (@e.paused? && "bg-warning") || "bg-success"
            ]}></span>
          </span>
          <span class={["font-semibold", (@e.paused? && "text-warning") || "text-success"]}>
            {if @e.paused?, do: "Paused", else: "Live"}
          </span>
          <span aria-hidden="true">·</span>
          <span class="min-w-0 truncate tabular-nums">
            {live_clock(@e.position)}<span :if={@e.duration > 0}> / {live_clock(@e.duration)}</span>
          </span>
        </p>
      </div>
    </.link>
    """
  end

  defp now_title(%{type: "tv", title: t, season: s, episode: e}) when s != nil and e != nil,
    do: "#{t} S#{s}E#{e}"

  defp now_title(%{title: t}), do: t

  defp live_clock(sec) when is_number(sec) do
    sec = trunc(sec)
    {h, m, s} = {div(sec, 3600), div(rem(sec, 3600), 60), rem(sec, 60)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end

  defp live_clock(_), do: "0:00"

  attr :run, :map, required: true
  attr :i, :integer, required: true

  # One card of the feed's row: who, what they did, to what, and the small print — a rating, the
  # day something was really watched, how far in — with how long ago. A group is a button that
  # opens the list of what is in it; a single title is a link to its page.
  defp activity_card(assigns) do
    assigns = assign(assigns, :d, Roki.Activity.describe(assigns.run))

    ~H"""
    <button
      :if={@run.batch?}
      type="button"
      phx-click="activity_open"
      phx-value-i={@i}
      class="group flex w-64 shrink-0 snap-start items-center gap-3 rounded-box border border-base-300 bg-base-100 p-2.5 text-left transition hover:bg-base-200 sm:w-72"
    >
      <.activity_body run={@run} d={@d} />
    </button>

    <.link
      :if={!@run.batch?}
      navigate={~p"/title/#{@run.type}/#{@run.tmdb_id}"}
      class="group flex w-64 shrink-0 snap-start items-center gap-3 rounded-box border border-base-300 bg-base-100 p-2.5 transition hover:bg-base-200 sm:w-72"
    >
      <.activity_body run={@run} d={@d} />
    </.link>
    """
  end

  attr :run, :map, required: true
  attr :d, :map, required: true

  defp activity_body(assigns) do
    ~H"""
    <div :if={@run.batch?} class="flex shrink-0 -space-x-6">
      <.activity_poster
        :for={i <- @run.items |> Enum.take(3) |> Enum.reverse()}
        poster={i.poster}
        class="h-16 w-11 ring-2 ring-base-100 group-hover:ring-base-200"
      />
    </div>
    <.activity_poster :if={!@run.batch?} poster={@run.poster} class="h-16 w-11 shrink-0" />

    <div class="min-w-0 flex-1 text-sm leading-snug">
      <p class="line-clamp-2">
        <span class="font-semibold">{@run.username}</span>
        <span class="text-base-content/70">{@d.verb}</span>
        <span :if={@d.subject} class="font-semibold">{@d.subject}</span>
        <span :if={@d.after} class="text-base-content/70">{@d.after}</span>
      </p>
      <p class="mt-0.5 flex items-center gap-1.5 text-xs text-base-content/60">
        <.icon name={@d.icon} class={["h-4 w-4 shrink-0", tone_text(@d.tone)]} />
        <span :if={@run.batch?} class="min-w-0 truncate text-primary">See which</span>
        <span :if={!@run.batch? and @d.detail} class="min-w-0 truncate">{@d.detail}</span>
        <span aria-hidden="true">·</span>
        <span class="shrink-0">{ago(@run.at)}</span>
      </p>
    </div>
    """
  end

  attr :run, :map, required: true

  # What is in a group: every title, each opening its page, with the day it was really watched
  # when it was put on an earlier one.
  defp activity_group(assigns) do
    assigns = assign(assigns, :d, Roki.Activity.describe(assigns.run))

    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-end justify-center bg-black/50 p-0 sm:items-center sm:p-4"
      phx-window-keydown="activity_close"
      phx-key="escape"
    >
      <div
        class="flex max-h-[85vh] w-full max-w-lg flex-col rounded-t-box bg-base-100 shadow-xl sm:rounded-box"
        phx-click-away="activity_close"
        role="dialog"
        aria-label="Titles in this group"
      >
        <div class="flex items-start justify-between gap-3 border-b border-base-300 p-4">
          <div class="min-w-0">
            <p class="font-semibold">
              {@run.username} {@d.verb}<span :if={@d.after}>{@d.after}</span>
            </p>
            <p class="text-xs text-base-content/60">{ago(@run.at)}</p>
          </div>
          <button
            type="button"
            phx-click="activity_close"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>
        <ul class="divide-y divide-base-300 overflow-y-auto">
          <li :for={i <- @run.items}>
            <.link
              navigate={~p"/title/#{i.type}/#{i.tmdb_id}"}
              class="flex items-center gap-3 p-3 transition hover:bg-base-200"
            >
              <.activity_poster poster={i.poster} class="h-16 w-11 shrink-0" />
              <span class="min-w-0 flex-1">
                <span class="block truncate font-medium">{i.title}</span>
                <span class="block text-xs text-base-content/60">
                  {if i.kind == "backdated" and i.watched_on,
                    do: "Watched " <> Calendar.strftime(i.watched_on, "%b %-d, %Y"),
                    else: ago(i.at)}
                </span>
              </span>
              <.icon name="hero-chevron-right-micro" class="h-4 w-4 opacity-40" />
            </.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :poster, :any, default: nil
  attr :class, :string, default: ""

  defp activity_poster(assigns) do
    ~H"""
    <img
      :if={@poster}
      src={Roki.Images.local(@poster)}
      srcset={Roki.Images.srcset(@poster)}
      sizes={Roki.Images.poster_sizes("4rem")}
      alt=""
      loading="lazy"
      decoding="async"
      class={["rounded-md bg-base-300 object-cover", @class]}
    />
    <div :if={!@poster} class={["rounded-md bg-base-300", @class]}></div>
    """
  end

  # (Spelled out: Tailwind cannot see a class built from a name.)
  defp tone_text("success"), do: "text-success"
  defp tone_text("info"), do: "text-info"
  defp tone_text("primary"), do: "text-primary"
  defp tone_text("warning"), do: "text-warning"
  defp tone_text("secondary"), do: "text-secondary"

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
        Enum.any?(Map.delete(assigns.shelves, :seasonal), fn {_k, s} ->
          s.loading? and s.items == []
        end)
      )

    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      flush
      bleed
      overlay
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/"
    >
      <%!-- Flush: the page lays itself out. On a wide screen the mood carousel and the rows reach
            the edges of the window; everything else keeps the old gutters and width. --%>
      <%!-- The carousel and the rows share a box so the mood's animation (`MoodFx`, mood_fx.js) can
            sit over the carousel on one canvas, clicks passing through. Off with
            `config :roki, mood_fx: false`. --%>
      <div id="mood-fx" phx-hook={@mood_fx? && "MoodFx"} class="relative">
        <canvas
          :if={@mood_fx?}
          id="mood-fx-canvas"
          phx-update="ignore"
          class="pointer-events-none absolute left-0 top-0 z-[25]"
          aria-hidden="true"
        ></canvas>
        <.mood_picker moods={@moods} start={@mood_start} />

        <.shelf_rows
          shelves={@shelves}
          season={@season}
          seen={@seen}
          upcoming={@upcoming}
          cached_titles={@cached_titles}
          signed_in?={@uuid != nil}
        />
      </div>

      <.pitch :if={@visitor?} />

      <%!-- Activity has its own wrapper: on a wide screen it runs the whole width, with the same
            gutters as the rows above. Its cards stay inside the gutters on both sides (bordered cards
            running off the edge of the window looked cut off). --%>
      <div :if={@uuid} class="mx-auto max-w-6xl px-4 pt-4 sm:px-6 lg:max-w-none lg:px-12 xl:px-16">
        <%!-- What people did lately, as one row to scroll along (or ignore): finished, started, saved,
            rated, put on an earlier day. Narrowed by kind and by whose. A group opens as a list. --%>
        <section :if={@uuid} class="space-y-2" aria-label="Activity" data-reveal>
          <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
            <h2 class="text-xl font-semibold">Activity</h2>
            <div
              class="ml-auto inline-flex rounded-full bg-base-200 p-0.5 sm:order-last sm:ml-0"
              role="group"
              aria-label="Whose activity"
            >
              <button
                :for={{who, label} <- [all: "Everyone", friends: "Friends", mine: "Me"]}
                type="button"
                phx-click="activity_who"
                phx-value-who={who}
                aria-pressed={to_string(@activity_who == who)}
                class={[
                  "rounded-full px-3 py-1 text-sm font-medium transition",
                  @activity_who == who && "bg-base-100 shadow-sm",
                  @activity_who != who && "text-base-content/70 hover:text-base-content"
                ]}
              >
                {label}
              </button>
            </div>
            <div
              class="flex w-full gap-1.5 overflow-x-auto sm:w-auto sm:flex-1 [scrollbar-width:none]"
              role="group"
              aria-label="Kind of activity"
            >
              <button
                :for={
                  {kind, label} <- [
                    {nil, "All"},
                    {"finished", "Finished"},
                    {"started", "Started"},
                    {"saved", "Saved"},
                    {"rated", "Rated"},
                    {"backdated", "Backdated"}
                  ]
                }
                type="button"
                phx-click="activity_kind"
                phx-value-kind={kind || ""}
                aria-pressed={to_string(@activity_kind == kind)}
                class={[
                  "btn btn-xs shrink-0 rounded-full border-0",
                  @activity_kind == kind && "btn-primary",
                  @activity_kind != kind && "bg-base-200"
                ]}
              >
                {label}
              </button>
            </div>
          </div>

          <div :if={@activity == nil} class="skeleton h-[5.25rem] w-full rounded-box"></div>

          <p
            :if={@activity == [] and @now == []}
            class="rounded-box border border-dashed border-base-300 px-4 py-5 text-center text-sm text-base-content/60"
          >
            {if @activity_who == :friends,
              do: "Nothing from your friends yet.",
              else: "Nothing here yet."}
          </p>

          <ul
            :if={@activity not in [nil, []] or @now != []}
            class="flex snap-x gap-2 overflow-x-auto rounded-box pb-2 [scrollbar-width:none]"
          >
            <li :for={e <- @now} class="contents">
              <.now_card e={e} />
            </li>
            <%!-- (The feed may still be loading while someone is already in the player.) --%>
            <li
              :for={{run, i} <- (@activity || []) |> Enum.take(30) |> Enum.with_index()}
              class="contents"
            >
              <.activity_card run={run} i={i} />
            </li>
          </ul>

          <.activity_group :if={@activity_open} run={@activity_open} />
        </section>
      </div>

      <div
        :if={@error != nil}
        class="mx-auto max-w-6xl space-y-4 px-4 pb-8 pt-4 sm:px-6 lg:px-8"
      >
        <p :if={@error == :no_tmdb_key} class="alert text-sm">
          Featured needs a TMDB key — set <code>TMDB_API_KEY</code> on the server.
        </p>
        <p :if={@error != :no_tmdb_key} class="alert alert-error text-sm">
          Couldn't reach TMDB just now. Try again in a minute.
        </p>
      </div>
      <%!-- Always drawn (the lists are static data, their posters arrive later): while the shelves
            above are still skeletons it holds the room, so a quick scroll never meets the end of the
            page and then finds more. --%>
      <.lists_row
        lists={Enum.take(@lists, @lists_shown)}
        total={length(@lists)}
        more?={@lists_shown < length(@lists)}
        posters={@list_posters}
      />
    </Layouts.app>
    """
  end

  attr :lists, :list, required: true
  attr :total, :integer, required: true
  attr :more?, :boolean, default: false
  attr :posters, :map, default: %{}

  # The curated franchise lists as a row of their own, like the rows of films: a dozen to begin
  # with and a tile that opens the rest (all seventy at once was most of the page). Each is a dark
  # card tinted by its own colour, with a fan of its posters when the site has them and, for someone
  # signed in, a thin line for how far through it they are.
  @doc false
  def lists_row(assigns) do
    ~H"""
    <section
      id="row-lists"
      phx-hook="ShelfRow"
      data-reveal
      data-kind="lists"
      data-more={to_string(@more?)}
      data-start="true"
      data-end="false"
      class="group/row pb-10 pt-2"
      aria-label="Lists"
    >
      <div class="relative z-10 mb-3 flex items-baseline justify-between gap-4 px-4 sm:px-6 lg:px-12 xl:px-16">
        <div>
          <h2 class="text-2xl font-semibold tracking-tight">Lists</h2>
          <p class="hidden text-sm text-base-content/60 sm:block">
            Franchises, start to finish, in release order
          </p>
        </div>
        <.link
          navigate={~p"/lists"}
          class="pointer-events-none flex items-center gap-0.5 text-sm font-medium text-base-content/60 opacity-0 transition hover:text-base-content group-hover/row:pointer-events-auto group-hover/row:opacity-100 group-data-[touched]/row:pointer-events-auto group-data-[touched]/row:opacity-100 focus-visible:pointer-events-auto focus-visible:opacity-100"
        >
          See All {@total} <.icon name="hero-chevron-right-micro" class="h-4 w-4" />
        </.link>
      </div>

      <div class="relative">
        <button
          type="button"
          data-row-prev
          aria-label="Scroll Lists back"
          class="absolute left-0 justify-start bg-gradient-to-r pl-2 z-30 hidden w-14 items-center from-black/40 via-black/15 to-transparent text-white opacity-0 transition-opacity duration-200 max-lg:!hidden group-data-[start=false]/row:flex group-hover/row:opacity-60 hover:opacity-100 focus-visible:opacity-100 inset-y-0"
        >
          <.icon
            name="hero-chevron-left"
            class="h-10 w-10 drop-shadow"
          />
        </button>
        <button
          type="button"
          data-row-next
          aria-label="Scroll Lists forward"
          class="absolute right-0 justify-end bg-gradient-to-l pr-2 z-30 hidden w-14 items-center from-black/40 via-black/15 to-transparent text-white opacity-0 transition-opacity duration-200 max-lg:!hidden group-data-[end=false]/row:flex group-hover/row:opacity-60 hover:opacity-100 focus-visible:opacity-100 inset-y-0"
        >
          <.icon
            name="hero-chevron-right"
            class="h-10 w-10 drop-shadow"
          />
        </button>

        <ul
          data-row-scroller
          class="flex snap-x scroll-px-4 gap-4 overflow-x-auto scroll-smooth px-4 pb-3 pt-1 [--card-w:clamp(9rem,11.2vw,14rem)] [scrollbar-width:none] sm:scroll-px-6 sm:px-6 lg:scroll-px-12 lg:px-12 xl:scroll-px-16 xl:px-16"
        >
          <.list_tile
            :for={{l, i} <- Enum.with_index(@lists)}
            list={l}
            index={i}
            posters={Map.get(@posters, l.slug, [])}
          />
          <li class="shrink-0 snap-start">
            <.link
              navigate={~p"/lists"}
              class="group/all flex h-[calc(var(--card-w)*1.5)] w-[calc(var(--card-w)*1.15)] flex-col items-center justify-center gap-3 rounded-box border border-dashed border-base-content/20 text-base-content/60 transition hover:border-primary/60 hover:text-base-content"
            >
              <span class="flex h-12 w-12 items-center justify-center rounded-full border border-current transition group-hover/all:border-primary group-hover/all:text-primary">
                <.icon name="hero-arrow-right" class="h-6 w-6" />
              </span>
              <span class="px-3 text-center text-sm font-medium leading-snug">
                All {@total} lists
              </span>
            </.link>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :list, :map, required: true
  attr :index, :integer, default: 0
  attr :posters, :list, default: []

  defp list_tile(assigns) do
    list = assigns.list

    assigns =
      assign(assigns,
        # The golden angle round the colour wheel: neighbours are never alike, however many.
        hue: rem(round(assigns.index * 137.508) + 190, 360),
        progress: RokiWeb.ListComponents.progress(list),
        percent:
          if(is_integer(list[:watched]) and list.count > 0,
            do: min(100, round(list.watched * 100 / list.count)),
            else: nil
          )
      )

    ~H"""
    <li class="shrink-0 snap-start">
      <.link
        navigate={~p"/lists/#{@list.slug}"}
        class="group/tile relative flex h-[calc(var(--card-w)*1.5)] w-[calc(var(--card-w)*2)] flex-col justify-end overflow-hidden rounded-box bg-neutral-950 p-4 text-white shadow-lg ring-1 ring-white/10 transition duration-300 hover:-translate-y-1 hover:ring-white/40 hover:shadow-2xl"
        style={"--hue: #{@hue}"}
      >
        <div
          class="absolute inset-0"
          style="background: radial-gradient(120% 90% at 88% -10%, hsl(var(--hue) 85% 48% / 0.55), transparent 62%), linear-gradient(160deg, hsl(var(--hue) 45% 15%) 0%, hsl(var(--hue) 55% 6%) 100%)"
          aria-hidden="true"
        >
        </div>
        <div
          class="absolute inset-0 opacity-[0.07] mix-blend-overlay"
          style="background-image: linear-gradient(rgb(255 255 255 / 0.8) 1px, transparent 1px), linear-gradient(90deg, rgb(255 255 255 / 0.8) 1px, transparent 1px); background-size: 22px 22px"
          aria-hidden="true"
        >
        </div>

        <div :if={@posters != []} class="absolute right-4 top-4 flex -space-x-9">
          <img
            :for={{url, i} <- Enum.with_index(@posters)}
            src={Roki.Images.local(url)}
            srcset={Roki.Images.srcset(url)}
            sizes={Roki.Images.poster_sizes()}
            alt=""
            loading="lazy"
            decoding="async"
            class="aspect-[2/3] h-[calc(var(--card-w)*0.92)] rounded-md object-cover shadow-xl ring-1 ring-white/25 transition duration-300 group-hover/tile:-translate-y-1"
            style={"transform: rotate(#{Enum.at([-7, 0, 7], i, 0)}deg); z-index: #{3 - i}"}
          />
        </div>

        <div class="relative">
          <p class="line-clamp-2 text-xl font-semibold leading-tight tracking-tight text-shadow-sm">
            {@list.name}
          </p>
          <p class="mt-0.5 text-xs text-white/65">
            {@list.count} titles{if @progress, do: " · #{@progress}"}
          </p>
          <div :if={@percent} class="mt-2 h-[3px] w-full overflow-hidden rounded-full bg-white/15">
            <div
              class="h-full rounded-full bg-gradient-to-r from-cyan-300 to-primary"
              style={"width: #{@percent}%"}
            >
            </div>
          </div>
        </div>
      </.link>
    </li>
    """
  end

  attr :class, :string, default: ""

  # The visitor's pitch. On a wide screen it sits under the rows (the header has the same buttons)
  # so the picture is what the page opens with.
  defp pitch(assigns) do
    ~H"""
    <section class={["mx-auto max-w-6xl px-4 pb-2 pt-10 text-center sm:px-6 lg:px-8", @class]}>
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
    """
  end

  attr :moods, :map, required: true
  attr :start, :string, default: nil

  # "What are you in the mood for?": one mood at a time, turning on a timer. The mood's lead picture
  # blurred into a field of colour, its three most popular titles fanned on the right (above the
  # words on a phone), and the moods as named tabs along the bottom, the shown one's line filling as
  # its turn runs — hover one to see it, click it to open it. The turning is the `MoodCarousel` hook's.
  # Dark in both themes: the words are white, and the header floats over it.
  @doc false
  def mood_picker(assigns) do
    all = Roki.Mood.all()
    start = if Enum.any?(all, &(&1.slug == assigns.start)), do: assigns.start, else: hd(all).slug
    assigns = assign(assigns, all: all, start: start)

    ~H"""
    <section
      id="mood-picker"
      data-fx-stage
      phx-hook="MoodCarousel"
      data-every="6000"
      data-start={@start}
      class="relative overflow-hidden bg-neutral-950"
      aria-label="What are you in the mood for?"
    >
      <%!-- The slides share one grid cell, so the box is as tall as the tallest of them: a long
            tagline makes every slide taller and never squeezes the posters or the button. --%>
      <div class="relative grid min-h-[clamp(34rem,74svh,46rem)] grid-cols-[minmax(0,1fr)] lg:min-h-[clamp(32rem,66svh,44rem)]">
        <div
          :for={m <- @all}
          data-mood={m.slug}
          class={[
            "relative col-start-1 row-start-1 flex transition-opacity duration-700",
            m.slug != @start && "pointer-events-none opacity-0"
          ]}
          aria-hidden={to_string(m.slug != @start)}
        >
          <% items = Map.get(@moods, m.slug, []) %>
          <% lead = List.first(items) %>
          <img
            :if={lead && lead[:backdrop]}
            src={Roki.Images.local(String.replace(lead.backdrop, "/w1280/", "/w780/"))}
            alt=""
            loading={if m.slug == @start, do: "eager", else: "lazy"}
            class="absolute inset-0 h-full w-full scale-105 object-cover opacity-50 blur-sm"
          />
          <div
            class="absolute inset-0"
            style={"background: radial-gradient(ellipse at 75% 40%, transparent 0%, hsl(#{m.hue} 25% 6%) 78%), linear-gradient(0deg, hsl(#{m.hue} 25% 5%) 0%, transparent 35%), linear-gradient(180deg, rgb(0 0 0 / 0.55) 0%, transparent 20%)"}
          >
          </div>

          <div class="relative grid w-full items-center gap-8 px-4 pb-24 pt-24 sm:px-6 lg:grid-cols-[minmax(0,1fr)_auto] lg:px-12 lg:pt-28 xl:px-16">
            <%!-- The posters: above the words on a phone, on the right on a wide screen. --%>
            <%!-- `mood-fan`: the three fan out from behind the first as the slide comes in (app.css);
                  `mood-posters`/`mood-words`: they drift at their own pace as the page scrolls. --%>
            <div class="mood-posters mood-fan relative mx-auto flex h-52 w-72 items-center justify-center sm:h-64 sm:w-96 lg:order-2 lg:h-[24rem] lg:w-[34rem]">
              <.link
                :for={
                  {it, k} <-
                    items |> Enum.filter(& &1[:poster]) |> Enum.take(3) |> Enum.with_index()
                }
                navigate={~p"/title/#{it.type}/#{it.id}"}
                title={it.title}
                class={[
                  "absolute aspect-[2/3] h-full overflow-hidden rounded-2xl bg-white/5 shadow-2xl ring-1 ring-white/10 hover:z-20",
                  k == 0 && "z-10"
                ]}
              >
                <img
                  src={Roki.Images.local(String.replace(it.poster, "/w500/", "/w342/"))}
                  srcset={Roki.Images.srcset(it.poster)}
                  sizes={Roki.Images.poster_sizes()}
                  alt={it.title}
                  loading={if m.slug == @start, do: "eager", else: "lazy"}
                  class="h-full w-full object-cover"
                />
              </.link>
            </div>

            <div class="mood-words text-center text-white lg:order-1 lg:text-left">
              <p
                class="text-xs font-semibold uppercase tracking-[0.25em]"
                style={"color: hsl(#{m.hue} 90% 62%)"}
              >
                What are you in the mood for?
              </p>
              <h1 class="mt-3 text-5xl font-bold leading-none tracking-tight sm:text-6xl lg:text-7xl">
                {m.label}
              </h1>
              <p class="mx-auto mt-4 max-w-lg text-base text-white/70 sm:text-lg lg:mx-0">
                {m.tagline}
              </p>
              <.link
                navigate={~p"/mood/#{m.slug}"}
                class="btn mt-6 h-12 rounded-full border-0 bg-white px-7 text-base text-neutral-900 shadow-lg hover:bg-white/90"
              >
                Show me all <.icon name="hero-arrow-right" class="h-5 w-5" />
              </.link>
            </div>
          </div>
        </div>
      </div>

      <%!-- The moods as named tabs; the shown one's line fills in its colour as its turn runs. As the
            page is scrolled down from the top they sink a little and dissolve from their bottom edge
            up, blurring as they go (`--tuck`, set by the hook), and come back as it returns. --%>
      <div
        data-mood-tabs
        class="mood-tabs absolute inset-x-0 bottom-4 z-10 px-4 sm:px-6 lg:px-12 xl:px-16"
      >
        <div
          class="flex gap-5 overflow-x-auto border-t border-white/10 [scrollbar-width:none]"
          role="tablist"
          aria-label="Moods"
        >
          <.link
            :for={m <- @all}
            navigate={~p"/mood/#{m.slug}"}
            data-mood-chip={m.slug}
            role="tab"
            aria-selected={to_string(m.slug == @start)}
            class="relative shrink-0 pb-1 pt-3 text-sm font-medium text-white/50 transition hover:text-white aria-selected:text-white"
          >
            <span class="absolute inset-x-0 -top-px h-0.5 overflow-hidden" aria-hidden="true">
              <span
                data-mood-bar
                class="absolute inset-0 origin-left scale-x-0"
                style={"background: hsl(#{m.hue} 90% 62%)"}
              ></span>
            </span>
            {m.label}
          </.link>
        </div>
      </div>
    </section>
    """
  end

  attr :shelves, :map, required: true
  attr :season, :map, default: nil
  attr :seen, :any, required: true
  attr :upcoming, :map, default: %{}
  attr :cached_titles, :any, default: nil

  attr :signed_in?, :boolean, default: false

  # One row each for films, shows and anime, side by side in nothing but scrolling — and, last, what
  # suits the time of year (the Seasonal row), which links to that season's own page.
  @doc false
  def shelf_rows(assigns) do
    seasonal = assigns.shelves[:seasonal]

    assigns =
      assign(
        assigns,
        :rows,
        [
          {:movies, "Trending Movies", "/movies"},
          {:shows, "Trending Shows", "/shows"},
          {:anime, "Anime Airing Now", "/anime"}
        ] ++
          if(assigns.season && seasonal && (seasonal.items != [] or seasonal.loading?),
            do: [
              {:seasonal, "Seasonal · #{assigns.season.label}", "/mood/#{assigns.season.slug}"}
            ],
            else: []
          )
      )

    ~H"""
    <div class="space-y-7 pb-4 pt-6 lg:space-y-9 lg:pb-6 lg:pt-8">
      <.shelf_row
        :for={{kind, title, href} <- @rows}
        kind={kind}
        title={title}
        href={href}
        shelf={@shelves[kind]}
        seen={@seen}
        upcoming={@upcoming}
        cached_titles={@cached_titles}
        signed_in?={@signed_in?}
      />
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :title, :string, required: true
  attr :href, :string, required: true
  attr :shelf, :map, required: true
  attr :seen, :any, required: true
  attr :upcoming, :map, default: %{}
  attr :cached_titles, :any, default: nil
  attr :signed_in?, :boolean, default: false

  # The chevrons belong to the row: they appear when the pointer is over it, the right one while
  # there is more to the right, the left one once it has been scrolled (`ShelfRow` keeps
  # `data-start` and `data-end` true).
  defp shelf_row(assigns) do
    ~H"""
    <section
      id={"row-#{@kind}"}
      phx-hook="ShelfRow"
      data-start="true"
      data-end="false"
      data-reveal
      class="group/row"
      aria-label={@title}
    >
      <%!-- Above the scroller: the scroller's top padding (room for the glow) reaches up over this
           row, and it would take the clicks meant for See All. --%>
      <div class="relative z-10 mb-3 flex items-baseline justify-between gap-4 px-4 sm:px-6 lg:px-12 xl:px-16">
        <h2 class="text-2xl font-semibold tracking-tight">{@title}</h2>
        <.link
          navigate={@href}
          class="pointer-events-none flex items-center gap-0.5 text-sm font-medium text-base-content/60 opacity-0 transition hover:text-base-content group-hover/row:pointer-events-auto group-hover/row:opacity-100 group-data-[touched]/row:pointer-events-auto group-data-[touched]/row:opacity-100 focus-visible:pointer-events-auto focus-visible:opacity-100"
        >
          See All <.icon name="hero-chevron-right-micro" class="h-4 w-4" />
        </.link>
      </div>

      <div class="relative [--card-w:clamp(9rem,11.2vw,14rem)]">
        <button
          type="button"
          data-row-prev
          aria-label={"Scroll #{@title} back"}
          class="absolute left-0 justify-start bg-gradient-to-r pl-2 z-30 hidden w-14 items-center from-black/40 via-black/15 to-transparent text-white opacity-0 transition-opacity duration-200 max-lg:!hidden group-data-[start=false]/row:flex group-hover/row:opacity-60 hover:opacity-100 focus-visible:opacity-100 top-4 h-[calc(var(--card-w)*1.5)]"
        >
          <.icon
            name="hero-chevron-left"
            class="h-10 w-10 drop-shadow"
          />
        </button>
        <button
          type="button"
          data-row-next
          aria-label={"Scroll #{@title} forward"}
          class="absolute right-0 justify-end bg-gradient-to-l pr-2 z-30 hidden w-14 items-center from-black/40 via-black/15 to-transparent text-white opacity-0 transition-opacity duration-200 max-lg:!hidden group-data-[end=false]/row:flex group-hover/row:opacity-60 hover:opacity-100 focus-visible:opacity-100 top-4 h-[calc(var(--card-w)*1.5)]"
        >
          <.icon
            name="hero-chevron-right"
            class="h-10 w-10 drop-shadow"
          />
        </button>

        <%!-- Room above and below the cards for the ring and the glow around the one under the
              pointer: a sideways scroller clips up and down too, at its own padding, and the glow
              was cut off square at the row's foot. The padding is taken back with negative margins,
              so the row takes the space it always did and the glow runs on under the next section. --%>
        <ul
          data-row-scroller
          data-card-row
          class="-mb-12 -mt-7 flex snap-x scroll-px-4 gap-4 overflow-x-auto scroll-smooth px-4 pb-16 pt-8 sm:scroll-px-6 sm:px-6 lg:scroll-px-12 lg:px-12 [--card-w:clamp(9rem,11.2vw,14rem)] [scrollbar-width:none] xl:scroll-px-16 xl:px-16"
        >
          <.shelf_card
            :for={i <- @shelf.items}
            kind={@kind}
            item={i}
            seen={MapSet.member?(@seen, {i.type, i.id})}
            cached_titles={@cached_titles}
            upcoming={@upcoming}
            signed_in?={@signed_in?}
          />
          <li
            :for={_ <- if(@shelf.items == [] and @shelf.loading?, do: 1..9, else: [])}
            class="w-[clamp(9rem,11.2vw,14rem)] shrink-0"
            aria-hidden="true"
          >
            <div class="aspect-[2/3] animate-pulse rounded-box bg-base-300"></div>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  # The score a poster's card shows, as text; nothing for none.
  defp card_vote(%{vote: v}) when is_number(v) and v > 0, do: Float.round(v * 1.0, 1)
  defp card_vote(_item), do: nil

  attr :item, :map, required: true
  attr :kind, :atom, required: true
  attr :seen, :boolean, default: false
  attr :cached_titles, :any, default: nil
  attr :signed_in?, :boolean, default: true
  attr :keep_colour?, :boolean, default: false
  slot :inner_block

  # One title in a list of posters: a film or a show opens into the card the rows have (the
  # `GridCards` hook, on a box round the list); anything else — a manga — is a plain poster.
  @doc false
  def tile(%{item: %{type: type}} = assigns) when type in ["movie", "tv"] do
    ~H"""
    <.grid_card
      kind={@kind}
      item={@item}
      seen={@seen}
      cached_titles={@cached_titles}
      signed_in?={@signed_in?}
      keep_colour?={@keep_colour?}
    >
      {render_slot(@inner_block)}
    </.grid_card>
    """
  end

  def tile(assigns) do
    ~H"""
    <li class="space-y-1">
      <.poster item={@item} seen={@seen} cached_titles={@cached_titles} compact title?={false} />
      {render_slot(@inner_block)}
    </li>
    """
  end

  attr :kind, :atom, required: true
  attr :item, :map, required: true
  attr :seen, :boolean, default: false
  attr :upcoming, :map, default: %{}
  attr :cached_titles, :any, default: nil
  attr :signed_in?, :boolean, default: false

  attr :no_card?, :boolean,
    default: false,
    doc: "the card does not open (a page that is selecting)"

  attr :keep_colour?, :boolean,
    default: false,
    doc: "the poster is never greyed for being watched (a list that is all watched titles)"

  slot :overlay, doc: "over the poster, under the card that opens"
  slot :inner_block, doc: "under the poster, outside the card that opens"

  # A title in a grid: the poster, and — on a wide screen with a mouse — the same card that opens
  # in the rows, laid over the middle of the cell (a grid has no room to push its neighbours aside).
  # A card at the edge of the grid opens towards the middle (`GridCards` marks it `data-edge`).
  @doc false
  def grid_card(assigns) do
    kind = if assigns.item.type == "movie", do: "movie", else: "tv"

    assigns =
      assign(assigns,
        key: "#{kind}/#{assigns.item.id}",
        title_href: RokiWeb.PosterComponents.href(assigns.item),
        play_href:
          if(kind == "movie",
            do: ~p"/sources/movie/#{assigns.item.id}?#{[auto: 1]}",
            else: RokiWeb.PosterComponents.href(assigns.item)
          ),
        picture: assigns.item[:poster] && Roki.Images.local(assigns.item.poster),
        srcset: Roki.Images.srcset(assigns.item[:poster]),
        vote: card_vote(assigns.item)
      )

    ~H"""
    <li
      data-card
      data-grid-card
      data-key={@key}
      data-signed={to_string(@signed_in?)}
      data-saved={to_string(@item[:saved] == true)}
      data-no-card={@no_card? && ""}
      data-keep-colour={@keep_colour? && ""}
      data-title={@item.title}
      data-year={@item[:year]}
      data-vote={@vote}
      data-title-href={@title_href}
      data-play-href={@play_href}
      data-picture={@picture}
      data-srcset={@srcset}
      class="space-y-1"
    >
      <%!-- The card opens in this box (`data-card-box`), over the cell's middle. --%>
      <div data-card-box class="group/card relative hover:z-20">
        <.poster
          item={@item}
          seen={@seen}
          upcoming={@upcoming}
          cached_titles={@cached_titles}
          compact
          title?={false}
          rating_corner={:top_left}
          mark?={false}
        />
        {render_slot(@overlay)}
      </div>
      {render_slot(@inner_block)}
    </li>
    """
  end

  attr :kind, :atom, required: true
  attr :item, :map, required: true
  attr :seen, :boolean, default: false
  attr :upcoming, :map, default: %{}
  attr :cached_titles, :any, default: nil
  attr :signed_in?, :boolean, default: false

  # One title in a row: a poster, and — when the pointer rests on it, on a wide screen with a
  # mouse — a card that opens around it. The card is wider and a little taller, with a wide picture
  # (the trailer, after a moment), Play, save and more, and the facts. The neighbours make way as
  # the poster's slot widens. What it shows beyond the poster comes from `/card/:type/:id`, fetched
  # by the `ShelfRow` hook once the card is open.
  @doc false
  def shelf_card(assigns) do
    kind = if assigns.item.type == "movie", do: "movie", else: "tv"

    assigns =
      assign(assigns,
        key: "#{kind}/#{assigns.item.id}",
        title_href: RokiWeb.PosterComponents.href(assigns.item),
        play_href:
          if(kind == "movie",
            do: ~p"/sources/movie/#{assigns.item.id}?#{[auto: 1]}",
            else: RokiWeb.PosterComponents.href(assigns.item)
          ),
        picture: assigns.item[:poster] && Roki.Images.local(assigns.item.poster),
        srcset: Roki.Images.srcset(assigns.item[:poster]),
        vote: card_vote(assigns.item)
      )

    ~H"""
    <li
      data-card
      data-key={@key}
      data-signed={to_string(@signed_in?)}
      data-saved={to_string(@item[:saved] == true)}
      data-title={@item.title}
      data-year={@item[:year]}
      data-vote={@vote}
      data-title-href={@title_href}
      data-play-href={@play_href}
      data-picture={@picture}
      data-srcset={@srcset}
      class="group/card relative h-[calc(var(--card-w)*1.5)] w-[var(--card-w)] shrink-0 snap-start hover:z-20"
    >
      <div class="h-full w-[var(--card-w)]">
        <.poster
          item={@item}
          seen={@seen}
          upcoming={@upcoming}
          compact
          title?={false}
          rating_corner={:top_left}
          mark?={false}
        />
      </div>
    </li>
    """
  end
end
