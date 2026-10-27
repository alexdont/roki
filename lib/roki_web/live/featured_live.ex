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

      start_async(socket, :activity, fn -> Roki.Activity.recent(60, Enum.reject(opts, &match?({_, nil}, &1))) end)
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
    run = with {n, ""} <- Integer.parse(i), list when is_list(list) <- socket.assigns.activity, do: Enum.at(list, n)
    {:noreply, assign(socket, :activity_open, if(is_map(run) and run.batch?, do: run))}
  end

  def handle_event("activity_close", _params, socket), do: {:noreply, assign(socket, :activity_open, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:activity, socket), do: {:noreply, load_activity(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  defp start(socket) do
    %{uuid: uuid, lists: lists} = socket.assigns
    socket = Enum.reduce(Featured.kinds(), socket, &fetch(&2, &1, 1))

    if uuid, do: Phoenix.PubSub.subscribe(Roki.PubSub, Roki.Activity.topic())
    socket = load_activity(socket)

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
              {@run.username} {@d.verb}<span :if={@d.after}> {@d.after}</span>
            </p>
            <p class="text-xs text-base-content/60">{ago(@run.at)}</p>
          </div>
          <button type="button" phx-click="activity_close" class="btn btn-ghost btn-sm btn-circle" aria-label="Close">
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>
        <ul class="divide-y divide-base-300 overflow-y-auto">
          <li :for={i <- @run.items}>
            <.link navigate={~p"/title/#{i.type}/#{i.tmdb_id}"} class="flex items-center gap-3 p-3 transition hover:bg-base-200">
              <.activity_poster poster={i.poster} class="h-16 w-11 shrink-0" />
              <span class="min-w-0 flex-1">
                <span class="block truncate font-medium">{i.title}</span>
                <span class="block text-xs text-base-content/60">
                  {if i.kind == "backdated" and i.watched_on, do: "Watched " <> Calendar.strftime(i.watched_on, "%b %-d, %Y"), else: ago(i.at)}
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
    <img :if={@poster} src={Roki.Images.local(@poster)} alt="" loading="lazy" class={["rounded-md bg-base-300 object-cover", @class]} />
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
    <Layouts.app socket={@socket}
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/home"
    >
      <section :if={@visitor?} class="py-10 text-center">
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

      <h1 :if={!@visitor?} class="text-2xl font-bold tracking-tight sm:text-3xl">Featured</h1>

      <%!-- What people did lately, as one row to scroll along (or ignore): finished, started, saved,
            rated, put on an earlier day. Narrowed by kind and by whose. A group opens as a list. --%>
      <section :if={@uuid} class="space-y-2" aria-label="Activity">
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <h2 class="text-xl font-semibold">Activity</h2>
          <div class="ml-auto inline-flex rounded-full bg-base-200 p-0.5 sm:order-last sm:ml-0" role="group" aria-label="Whose activity">
            <button
              :for={{who, label} <- [all: "Everyone", friends: "Friends", mine: "Me"]}
              type="button"
              phx-click="activity_who"
              phx-value-who={who}
              aria-pressed={to_string(@activity_who == who)}
              class={["rounded-full px-3 py-1 text-sm font-medium transition", @activity_who == who && "bg-base-100 shadow-sm", @activity_who != who && "text-base-content/70 hover:text-base-content"]}
            >
              {label}
            </button>
          </div>
          <div class="-mx-4 flex w-[calc(100%+2rem)] gap-1.5 overflow-x-auto px-4 sm:mx-0 sm:w-auto sm:flex-1 sm:px-0 [scrollbar-width:none]" role="group" aria-label="Kind of activity">
            <button
              :for={{kind, label} <- [{nil, "All"}, {"finished", "Finished"}, {"started", "Started"}, {"saved", "Saved"}, {"rated", "Rated"}, {"backdated", "Backdated"}]}
              type="button"
              phx-click="activity_kind"
              phx-value-kind={kind || ""}
              aria-pressed={to_string(@activity_kind == kind)}
              class={["btn btn-xs shrink-0 rounded-full border-0", @activity_kind == kind && "btn-primary", @activity_kind != kind && "bg-base-200"]}
            >
              {label}
            </button>
          </div>
        </div>

        <div :if={@activity == nil} class="skeleton h-[5.25rem] w-full rounded-box"></div>

        <p :if={@activity == []} class="rounded-box border border-dashed border-base-300 px-4 py-5 text-center text-sm text-base-content/60">
          {if @activity_who == :friends, do: "Nothing from your friends yet.", else: "Nothing here yet."}
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
        class="flex items-center justify-center gap-3 py-24 text-base-content/60"
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
        <.shelf
          :for={kind <- [:movies, :shows, :anime]}
          kind={kind}
          title={@titles[kind]}
          shelf={@shelves[kind]}
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
    </Layouts.app>
    """
  end

  attr :kind, :atom, required: true
  attr :title, :string, required: true
  attr :shelf, :map, required: true
  attr :seen, :any, required: true
  attr :upcoming, :map, default: %{}
  attr :cached_titles, :any, default: nil

  defp shelf(assigns) do
    ~H"""
    <section :if={@shelf.items != []} class="space-y-3">
      <div class="flex items-baseline justify-between gap-3">
        <h2 class="text-xl font-semibold">{@title}</h2>
        <.link
          navigate={"/#{@kind}"}
          class="btn btn-sm btn-primary btn-outline gap-1.5 rounded-full px-4"
        >
          See more <.icon name="hero-arrow-right" class="h-4 w-4" />
        </.link>
      </div>
      <%!-- Two rows: the rest of the list is on its own page, so this one stays short. --%>
      <ul class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
        <li :for={i <- Enum.take(@shelf.items, 16)} class="space-y-1">
          <.poster
            item={i}
            seen={MapSet.member?(@seen, {i.type, i.id})}
            cached_titles={@cached_titles}
            upcoming={@upcoming}
            compact
          />
        </li>
      </ul>
    </section>
    """
  end
end
