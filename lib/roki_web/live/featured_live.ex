defmodule RokiWeb.FeaturedLive do
  @moduledoc """
  `/home` — what is popular right now: movies, shows and anime. Public; the
  same page for a visitor and a signed-in user, with the pitch on top only for
  a visitor. Each shelf ends in a poster-sized "Load more" tile that loads the next
  TMDB page, like laev's Featured screen. A signed-in user who has connected
  laev sees what they have already watched greyed out.
  """
  use RokiWeb, :live_view

  import RokiWeb.ListComponents
  import RokiWeb.PosterComponents

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Featured

  @titles %{movies: "Trending movies", shows: "Trending shows", anime: "Anime airing now"}

  @impl true
  def mount(_params, _session, socket) do
    shelves =
      Map.new(Featured.kinds(), &{&1, %{items: [], page: 0, more?: false, loading?: true}})

    socket =
      socket
      |> assign(:page_title, "Featured")
      |> assign(:shelves, shelves)
      |> assign(:error, nil)
      |> assign(:seen, MapSet.new())
      |> assign(:upcoming, %{})
      |> assign(:uuid, uuid(socket))
      |> assign(:activity, if(uuid(socket), do: nil, else: []))
      |> assign(activity_kind: nil, activity_who: :all, activity_open: nil)
      |> assign(:lists, Enum.map(Roki.Lists.summaries(), &Map.put(&1, :watched, nil)))
      # The mood picker: what is held already is drawn in the first render, the rest arrives.
      |> assign(:moods, Roki.Mood.hero_peek())

    {:ok, if(connected?(socket), do: start(socket), else: socket)}
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

  @impl true
  def handle_event("activity_kind", %{"kind" => kind}, socket) do
    kind = if kind in Roki.Activity.kinds(), do: kind
    {:noreply, socket |> assign(activity_kind: kind, activity_open: nil) |> load_activity()}
  end

  def handle_event("activity_who", %{"who" => who}, socket) do
    who = Enum.find([:all, :friends, :mine], :all, &(Atom.to_string(&1) == who))
    {:noreply, socket |> assign(activity_who: who, activity_open: nil) |> load_activity()}
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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:activity, socket), do: {:noreply, load_activity(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  defp start(socket) do
    %{uuid: uuid, lists: lists} = socket.assigns
    socket = Enum.reduce(Featured.kinds(), socket, &fetch(&2, &1, 1))

    if uuid, do: Phoenix.PubSub.subscribe(Roki.PubSub, Roki.Activity.topic())
    socket = load_activity(socket)
    socket = start_async(socket, :moods, fn -> Roki.Mood.hero(uuid) end)

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

  @impl true
  def handle_async({:page, kind}, {:ok, {page, {:ok, items, more?}, seen}}, socket) do
    shelf = socket.assigns.shelves[kind]
    known = MapSet.new(shelf.items, & &1.id)
    fresh = Enum.reject(items, &MapSet.member?(known, &1.id))
    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(:seen, MapSet.union(socket.assigns.seen, seen))
     |> start_async({:dates, kind, page}, fn -> Roki.Watch.upcoming(uuid, fresh) end)
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

  # (A filter change keeps the old list on screen until the new one is in.)

  def handle_async(:activity, _other, socket), do: {:noreply, socket}

  def handle_async(:progress, {:ok, lists}, socket), do: {:noreply, assign(socket, :lists, lists)}
  def handle_async(:progress, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async({:page, kind}, {:exit, reason}, socket),
    do: {:noreply, failed(socket, kind, reason)}

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
      alt=""
      loading="lazy"
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
        Enum.any?(assigns.shelves, fn {_k, s} -> s.loading? and s.items == [] end)
      )

    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      flush
      bleed
      overlay
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/home"
    >
      <%!-- Flush: the page lays itself out. On a wide screen the mood carousel and the rows reach
            the edges of the window; everything else keeps the old gutters and width. --%>
      <.pitch :if={@visitor?} class="lg:hidden" />

      <div class="px-4 pt-8 sm:px-6 lg:p-0">
        <.mood_picker moods={@moods} />
      </div>

      <.shelf_rows
        shelves={@shelves}
        seen={@seen}
        upcoming={@upcoming}
        cached_titles={@cached_titles}
      />

      <.pitch :if={@visitor?} class="hidden lg:block" />

      <div class="mx-auto max-w-6xl space-y-4 px-4 pb-8 pt-4 sm:px-6 lg:px-8">
        <%!-- What people did lately, as one row to scroll along (or ignore): finished, started, saved,
            rated, put on an earlier day. Narrowed by kind and by whose. A group opens as a list. --%>
        <section :if={@uuid} class="space-y-2" aria-label="Activity">
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
              class="-mx-4 flex w-[calc(100%+2rem)] gap-1.5 overflow-x-auto px-4 sm:mx-0 sm:w-auto sm:flex-1 sm:px-0 [scrollbar-width:none]"
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
            :if={@activity == []}
            class="rounded-box border border-dashed border-base-300 px-4 py-5 text-center text-sm text-base-content/60"
          >
            {if @activity_who == :friends,
              do: "Nothing from your friends yet.",
              else: "Nothing here yet."}
          </p>

          <ul
            :if={@activity not in [nil, []]}
            class="-mx-4 flex snap-x scroll-px-4 gap-2 overflow-x-auto px-4 pb-2 sm:mx-0 sm:scroll-px-0 sm:px-0"
          >
            <li :for={{run, i} <- @activity |> Enum.take(30) |> Enum.with_index()} class="contents">
              <.activity_card run={run} i={i} />
            </li>
          </ul>

          <.activity_group :if={@activity_open} run={@activity_open} />
        </section>

        <div
          :if={@loading? and @error == nil}
          class="flex items-center justify-center gap-3 py-24 text-base-content/60 lg:hidden"
        >
          <span class="loading loading-spinner"></span> Loading what's popular…
        </div>

        <p :if={@error == :no_tmdb_key} class="alert text-sm">
          Featured needs a TMDB key — set <code>TMDB_API_KEY</code> on the server.
        </p>
        <p :if={@error not in [nil, :no_tmdb_key]} class="alert alert-error text-sm">
          Couldn't reach TMDB just now. Try again in a minute.
        </p>

        <div class="space-y-10">
          <%!-- Everything that is popular right now, films, shows and anime in one grid; each tab in
              the header has the whole of its own list. --%>
          <.popular_now
            shelves={@shelves}
            seen={@seen}
            upcoming={@upcoming}
            cached_titles={@cached_titles}
          />

          <%!-- Last, and only once the shelves above have settled, so it can never push
              anything down. Curated franchises and TMDB collections, start to finish. --%>
          <section :if={not @loading?} class="space-y-3">
            <div class="flex items-baseline justify-between gap-3">
              <h2 class="text-xl font-semibold">Lists</h2>
              <p class="hidden text-sm text-base-content/60 sm:block">
                Franchises start to finish, in release order
              </p>
            </div>
            <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              <.list_card :for={l <- @lists} list={l} />
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
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

  # "What are you feeling like today?": one mood at a time, turning on a timer, each on the
  # backdrop of what is popular in it with a strip of those posters; the row of moods under it
  # — hover one to see it, click it to open it. The turning is the `MoodCarousel` hook's.
  @doc false
  def mood_picker(assigns) do
    assigns = assign(assigns, :all, Roki.Mood.all())

    ~H"""
    <section
      id="mood-picker"
      phx-hook="MoodCarousel"
      data-every="6000"
      class="relative space-y-3 lg:space-y-0"
      aria-label="What are you feeling like today?"
    >
      <%!-- The slides are stacked in one grid cell, so the box is as tall as the tallest of them:
            a long title or a tagline that wraps makes every slide taller, and never squeezes the
            posters or the button, whatever the width of the screen. --%>
      <div class="relative grid min-h-[26rem] grid-cols-[minmax(0,1fr)] overflow-hidden rounded-3xl bg-base-300 shadow-xl sm:min-h-[28rem] lg:min-h-[clamp(30rem,62svh,44rem)] lg:rounded-none lg:shadow-none">
        <%!-- One slide per mood; the hook shows one. --%>
        <div
          :for={{m, i} <- Enum.with_index(@all)}
          data-mood={m.slug}
          class={[
            "relative col-start-1 row-start-1 flex transition-opacity duration-700",
            i != 0 && "pointer-events-none opacity-0"
          ]}
          aria-hidden={to_string(i != 0)}
        >
          <% items = Map.get(@moods, m.slug, []) %>
          <% lead = List.first(items) %>
          <img
            :if={lead && lead[:backdrop]}
            src={Roki.Images.local(lead.backdrop)}
            alt=""
            loading={if i == 0, do: "eager", else: "lazy"}
            class="mood-backdrop absolute inset-0 h-full w-full object-cover"
          />
          <div class="mood-grain absolute inset-0 opacity-[0.14] mix-blend-overlay" aria-hidden="true">
          </div>
          <div
            class="absolute inset-0 lg:hidden"
            style={"background: linear-gradient(90deg, hsl(#{m.hue} 70% 12% / 0.96) 0%, hsl(#{m.hue} 70% 12% / 0.80) 45%, hsl(#{m.hue} 70% 12% / 0.25) 100%), linear-gradient(0deg, hsl(#{m.hue} 70% 10% / 0.9) 0%, transparent 45%)"}
          >
          </div>
          <%!-- Wide screens: the picture is the point. Dark where the words are, clear on the right,
                and a fade along the bottom for the posters' edge to sit against. --%>
          <div
            class="absolute inset-0 hidden lg:block"
            style={"background: linear-gradient(90deg, hsl(#{m.hue} 60% 7% / 0.92) 0%, hsl(#{m.hue} 60% 7% / 0.62) 32%, hsl(#{m.hue} 60% 7% / 0.08) 66%, transparent 100%), linear-gradient(0deg, hsl(#{m.hue} 60% 6% / 0.82) 0%, transparent 38%), linear-gradient(180deg, hsl(#{m.hue} 60% 6% / 0.4) 0%, transparent 22%)"}
          >
          </div>

          <div class="relative flex w-full flex-col justify-between gap-6 p-5 text-white sm:p-8 lg:justify-end lg:px-12 lg:pb-20 xl:px-16">
            <div class="max-w-xl space-y-3 sm:max-w-3xl lg:max-w-4xl lg:space-y-4">
              <%!-- Numbered the way a programme numbers its films: where a pictogram would stand. --%>
              <p class="flex items-center gap-3 text-[0.65rem] font-semibold uppercase tracking-[0.2em] text-white/70 sm:text-xs sm:tracking-[0.25em]">
                <span class="font-mono tabular-nums text-white">{Roki.Mood.number(m)}</span>
                <span class="hidden h-px w-8 bg-white/40 sm:block" aria-hidden="true"></span>
                What are you feeling like today?
              </p>
              <h1
                class="mood-title text-4xl leading-[0.95] tracking-tight min-[400px]:text-5xl sm:text-7xl lg:text-8xl"
                style={"font-family: #{m.font}; --mood: hsl(#{m.hue} 90% 62%)"}
              >
                {m.label}
              </h1>
              <div
                class="h-1 w-14 rounded-full"
                style={"background: hsl(#{m.hue} 90% 62%)"}
                aria-hidden="true"
              >
              </div>
              <p class="text-base text-white/80 sm:text-lg">{m.tagline}</p>
              <.link
                navigate={~p"/mood/#{m.slug}"}
                class="btn h-11 rounded-full border-0 bg-white px-5 text-neutral-900 shadow-lg hover:bg-white/90"
              >
                Show me <.icon name="hero-arrow-right" class="h-4 w-4" />
              </.link>
            </div>

            <%!-- What is popular in it right now; each poster is its title. --%>
            <div
              :if={items != []}
              class="-mx-5 flex shrink-0 gap-2 overflow-x-auto px-5 pb-1 [scrollbar-width:none] sm:-mx-8 sm:px-8 lg:hidden"
            >
              <.link
                :for={t <- Enum.take(items, 10)}
                navigate={~p"/title/#{t.type}/#{t.id}"}
                class="w-[4.5rem] shrink-0 overflow-hidden rounded-lg bg-white/10 shadow-lg ring-1 ring-white/20 transition hover:-translate-y-1 hover:ring-white/60 sm:w-24"
                title={t.title}
              >
                <img
                  :if={t.poster}
                  src={Roki.Images.local(t.poster)}
                  alt={t.title}
                  loading="lazy"
                  class="aspect-[2/3] h-auto w-full object-cover"
                />
                <div :if={!t.poster} class="aspect-[2/3] w-full"></div>
              </.link>
            </div>
            <div :if={items == []} class="flex shrink-0 gap-2 lg:hidden">
              <div
                :for={_ <- 1..6}
                class="aspect-[2/3] w-[4.5rem] shrink-0 animate-pulse rounded-lg bg-white/15 sm:w-24"
              >
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Wide screens: the moods as short bars in the corner of the picture, the shown one filling
            as its turn runs; hover one for its name and to see it, click to open it. --%>
      <div
        class="absolute bottom-8 right-12 z-10 hidden items-center gap-1 lg:flex xl:right-16"
        role="tablist"
        aria-label="Moods"
      >
        <.link
          :for={{m, i} <- Enum.with_index(@all)}
          navigate={~p"/mood/#{m.slug}"}
          data-mood-chip={m.slug}
          role="tab"
          aria-selected={to_string(i == 0)}
          aria-label={m.label}
          class="group/bar relative flex h-6 w-9 items-center"
        >
          <span class="relative block h-[3px] w-full overflow-hidden rounded-full bg-white/30 transition-colors group-hover/bar:bg-white/60 group-aria-selected/bar:bg-white/50">
            <span
              data-mood-bar
              class="absolute inset-0 origin-left scale-x-0 rounded-full bg-white"
              aria-hidden="true"
            ></span>
          </span>
          <span class="pointer-events-none absolute bottom-full right-0 mb-1 whitespace-nowrap rounded-md bg-black/80 px-2 py-1 text-xs font-medium text-white opacity-0 shadow transition group-hover/bar:opacity-100">
            {m.label}
          </span>
        </.link>
      </div>

      <%!-- The moods, in a row: the shown one is lit, with a thin line that fills as its turn runs. --%>
      <div
        class="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1 [scrollbar-width:none] sm:mx-0 sm:flex-wrap sm:px-0 lg:hidden"
        role="tablist"
        aria-label="Moods"
      >
        <.link
          :for={{m, i} <- Enum.with_index(@all)}
          navigate={~p"/mood/#{m.slug}"}
          data-mood-chip={m.slug}
          role="tab"
          aria-selected={to_string(i == 0)}
          class="group relative shrink-0 overflow-hidden rounded-full border border-base-300 bg-base-100 px-3.5 py-2 text-sm font-semibold transition hover:border-base-content/30 aria-selected:border-transparent aria-selected:text-white aria-selected:shadow-md"
          style={"--mood: hsl(#{m.hue} 75% 45%); --mood-font: #{m.font}"}
        >
          <span
            class="absolute inset-0 bg-[var(--mood)] opacity-0 transition-opacity duration-300 group-aria-selected:opacity-100"
            aria-hidden="true"
          ></span>
          <%!-- The dot and the name are set three times in one cell. The two invisible copies are
               them as they are when the chip is lit and as they are when it is not, so the chip is
               as wide as the wider of the two all the time and the ones beside it never move; the
               visible copy changes style inside that room, the dot and the name centred together
               so the spare room falls evenly on both sides. (One invisible copy was not enough: a
               mood whose typeface is slimmer than the normal one got narrower when lit, and moved
               the rest instead.) A chip that changed size when it lit pushed every chip after it
               along, on every turn. --%>
          <span class="relative grid">
            <span
              class="invisible col-start-1 row-start-1 flex items-center gap-2 text-base leading-5 tracking-wide"
              style={"font-family: #{m.font}"}
              aria-hidden="true"
            >
              <span class="h-2 w-2 shrink-0"></span>{m.label}
            </span>
            <span
              class="invisible col-start-1 row-start-1 flex items-center gap-2 leading-5"
              aria-hidden="true"
            >
              <span class="h-2 w-2 shrink-0"></span>{m.label}
            </span>
            <span class="col-start-1 row-start-1 flex items-center justify-center gap-2 leading-5 group-aria-selected:[font-family:var(--mood-font)] group-aria-selected:text-base group-aria-selected:tracking-wide">
              <span
                class="h-2 w-2 shrink-0 rounded-full bg-[var(--mood)] transition-colors group-aria-selected:bg-white"
                aria-hidden="true"
              ></span>{m.label}
            </span>
          </span>
          <span
            data-mood-bar
            class="absolute inset-x-0 bottom-0 h-0.5 origin-left scale-x-0 bg-white/80"
            aria-hidden="true"
          ></span>
        </.link>
      </div>
    </section>
    """
  end

  attr :shelves, :map, required: true
  attr :seen, :any, required: true
  attr :upcoming, :map, default: %{}
  attr :cached_titles, :any, default: nil

  # A wide screen: one row each for films, shows and anime, side by side in nothing but scrolling.
  # (A phone has the three together as one grid, `popular_now/1`.)
  @doc false
  def shelf_rows(assigns) do
    assigns =
      assign(assigns, :rows, [
        {:movies, "Trending Movies", "/movies"},
        {:shows, "Trending Shows", "/shows"},
        {:anime, "Anime Airing Now", "/anime"}
      ])

    ~H"""
    <div class="hidden space-y-9 pb-6 pt-8 lg:block">
      <.shelf_row
        :for={{kind, title, href} <- @rows}
        kind={kind}
        title={title}
        href={href}
        shelf={@shelves[kind]}
        seen={@seen}
        upcoming={@upcoming}
        cached_titles={@cached_titles}
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
      class="group/row"
      aria-label={@title}
    >
      <div class="mb-3 flex items-baseline justify-between gap-4 px-12 xl:px-16">
        <h2 class="text-2xl font-semibold tracking-tight">{@title}</h2>
        <.link
          navigate={@href}
          class="flex items-center gap-0.5 text-sm font-medium text-base-content/60 opacity-0 transition hover:text-base-content group-hover/row:opacity-100 focus-visible:opacity-100"
        >
          See All <.icon name="hero-chevron-right-micro" class="h-4 w-4" />
        </.link>
      </div>

      <div class="relative">
        <button
          type="button"
          data-row-prev
          aria-label={"Scroll #{@title} back"}
          class="absolute inset-y-0 left-0 z-10 hidden w-16 items-center justify-start bg-gradient-to-r from-black/55 to-transparent pl-3 text-white opacity-0 transition group-hover/row:group-data-[start=false]/row:flex group-hover/row:group-data-[start=false]/row:opacity-100"
        >
          <.icon name="hero-chevron-left" class="h-8 w-8 drop-shadow" />
        </button>
        <button
          type="button"
          data-row-next
          aria-label={"Scroll #{@title} forward"}
          class="absolute inset-y-0 right-0 z-10 hidden w-16 items-center justify-end bg-gradient-to-l from-black/55 to-transparent pr-3 text-white opacity-0 transition group-hover/row:group-data-[end=false]/row:flex group-hover/row:group-data-[end=false]/row:opacity-100"
        >
          <.icon name="hero-chevron-right" class="h-8 w-8 drop-shadow" />
        </button>

        <ul
          data-row-scroller
          class="flex snap-x scroll-px-12 gap-4 overflow-x-auto scroll-smooth px-12 pb-3 pt-1 [scrollbar-width:none] xl:scroll-px-16 xl:px-16"
        >
          <li
            :for={i <- @shelf.items}
            class="w-[clamp(9rem,11.2vw,14rem)] shrink-0 snap-start"
          >
            <.poster
              item={i}
              seen={MapSet.member?(@seen, {i.type, i.id})}
              cached_titles={@cached_titles}
              upcoming={@upcoming}
              compact
              title?={false}
              rating_corner={:top_left}
            />
          </li>
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

  # The three popular lists as one: film, show, anime, film, show, anime… (popularity is not
  # comparable across them, so by rank), each poster saying what it is.
  defp popular_now(assigns) do
    items =
      [:movies, :shows, :anime]
      |> Enum.map(fn kind -> {kind, Enum.take(assigns.shelves[kind].items, 12)} end)
      |> interleave()
      |> Enum.uniq_by(fn {_k, i} -> {i.type, i.id} end)
      |> Enum.take(24)
      |> Enum.map(fn {kind, i} ->
        Map.put(i, :kind_label, %{movies: "Film", shows: "Show", anime: "Anime"}[kind])
      end)

    assigns = assign(assigns, :items, items)

    ~H"""
    <section :if={@items != []} class="space-y-3 lg:hidden" aria-label="Popular right now">
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <div>
          <h2 class="text-xl font-semibold">Popular right now</h2>
          <p class="text-sm text-base-content/60">Films, shows and anime, all together.</p>
        </div>
        <div class="flex gap-1.5">
          <.link
            :for={{kind, label} <- [movies: "Movies", shows: "Shows", anime: "Anime"]}
            navigate={"/#{kind}"}
            class="btn btn-sm rounded-full"
          >
            {label} <.icon name="hero-arrow-right-micro" class="h-4 w-4" />
          </.link>
        </div>
      </div>
      <ul class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
        <li :for={i <- @items} class="space-y-1">
          <.poster
            item={i}
            seen={MapSet.member?(@seen, {i.type, i.id})}
            cached_titles={@cached_titles}
            upcoming={@upcoming}
            compact
          />
          <p class="truncate text-[0.65rem] font-semibold uppercase tracking-wider text-base-content/45">
            {i.kind_label}
          </p>
        </li>
      </ul>
    </section>
    """
  end

  # [{kind, [items]}] → [{kind, item}], one of each in turn.
  defp interleave(lists) do
    lists = Enum.reject(lists, fn {_k, l} -> l == [] end)

    if lists == [] do
      []
    else
      heads = for {k, [h | _]} <- lists, do: {k, h}
      heads ++ interleave(for {k, [_ | t]} <- lists, do: {k, t})
    end
  end
end
