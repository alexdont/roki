defmodule RokiWeb.UserHomeLive do
  @moduledoc """
  `/:username/home` — one user's own shelf.

  Only that signed-in user sees it: anyone else is sent to the featured page,
  and a visitor to the login. The shelf appears once they have *chosen* to
  connect laev — pasting their laev key pulls their watchlist, resume points
  and history in from wherever that key syncs. Nothing about laev happens at
  sign-up, and accounts are never linked to each other.
  """
  use RokiWeb, :live_view

  @completed_page 100

  import RokiWeb.PosterComponents

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Laev

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    cond do
      !(scope && Scope.authenticated?(scope)) ->
        {:ok, push_navigate(socket, to: "/phoenix_kit/users/log-in")}

      !same_user?(Scope.user(scope).username, username) ->
        {:ok, push_navigate(socket, to: ~p"/home")}

      true ->
        uuid = Scope.user_uuid(scope)

        # The last shelf this account had, if one is kept: shown at once — in the page the
        # server sends, not only once the socket is up — and checked again behind it. Without
        # one the skeleton stands in, as it always did.
        {state, kept} =
          cond do
            !Laev.connected?(uuid) -> {:not_connected, :miss}
            true -> {:loading, Laev.cached_shelf(uuid)}
          end

        {state, data} =
          case kept do
            {:ok, data, _age} -> {:ready, data}
            :miss -> {state, nil}
          end

        socket =
          socket
          |> assign(:page_title, "Home")
          |> assign(:username, username)
          |> assign(:uuid, uuid)
          |> assign(:granted, Roki.Keys.granted?(uuid))
          |> assign(:state, state)
          |> assign(:data, data)
          |> assign(:busy, nil)
          |> assign(:error, nil)
          |> assign(:open, MapSet.new())
          |> assign(:stats, kept_stats(state, uuid))
          |> assign(:pulse, nil)
          |> assign(:completed, nil)
          |> assign(:ratings, if(connected?(socket), do: Roki.Profile.ratings(uuid), else: %{}))
          |> assign(:completed_shown, @completed_page)
          |> assign(:reading, List.first(Roki.Manga.Library.list_reading(uuid)))
          # Known from the reader's own tables, so it is there on the first paint.
          |> assign(:manga_totals, Roki.Manga.Library.reading_totals(uuid))
          |> assign(:client, RokiWeb.Client.key(socket, uuid))
          |> assign(:form, to_form(%{"key" => "", "url" => "", "carry" => "false"}, as: :laev))

        socket =
          cond do
            not connected?(socket) -> socket
            socket.assigns.state == :loading -> load(socket)
            # A kept shelf is already on screen: look again, in place, unless it is so recent
            # that looking would only repeat itself.
            socket.assigns.state == :ready -> revisit(socket, kept)
            # An account that uses the site's keys has nothing to fill in: it is set up here.
            socket.assigns.granted -> start_granted_setup(socket)
            true -> socket
          end

        {:ok, socket}
    end
  end

  # The strip's last figures, when this account is connected and has any kept: on the first
  # frame, so there is no placeholder to be swapped for them. They are measured again behind the
  # page and replaced in place.
  defp kept_stats(:not_connected, _uuid), do: nil

  defp kept_stats(_state, uuid) do
    case Roki.Profile.kept_totals(uuid) do
      {:ok, totals} -> totals
      :miss -> nil
    end
  end

  defp same_user?(mine, requested) when is_binary(mine),
    do: String.downcase(mine) == String.downcase(requested)

  defp same_user?(_, _), do: false

  defp start_granted_setup(socket) do
    uuid = socket.assigns.uuid

    socket
    |> assign(busy: "Setting up your account…")
    |> start_async(:connect, fn -> Laev.setup_granted(uuid) end)
  end

  # First load / after connecting: the skeleton shows until the shelf arrives.
  defp load(socket) do
    socket |> assign(state: :loading, data: nil, pulse: nil) |> reload()
  end

  # The page is showing a kept shelf. Everything else it needs is fetched straight away; the
  # shelf itself is only re-read when the kept one is old enough to have changed.
  defp revisit(socket, {:ok, _data, age}) do
    if age > Laev.shelf_fresh_s(), do: reload(socket), else: start_side(socket)
  end

  # A refresh (sync, or a kept shelf being checked): the page stays exactly as it is and the new
  # data replaces the old in place — nothing blanks, nothing moves.
  defp reload(socket) do
    uuid = socket.assigns.uuid

    socket
    |> start_async(:overview, fn -> Laev.shelf(uuid) end)
    |> start_side()
  end

  # What else the page draws. None of it needs the shelf, so none of it waits for it: these used
  # to start when the shelf arrived, which put a second and a half of waiting after the first
  # second and a half on a cold start.
  defp start_side(socket) do
    %{uuid: uuid, client: client} = socket.assigns

    socket
    |> start_async(:completed, fn -> Roki.Profile.history(uuid) end)
    |> start_async(:stats, fn -> Roki.Profile.totals(uuid) end)
    |> start_async(:pulse, fn -> Roki.Calendar.load(client, uuid) end)
  end

  # Posters for the part of Completed on screen: titles laev has never drawn have none yet, and
  # reading them is a TMDB request each, once — so only the rows shown, not all of them.
  defp fetch_posters(%{assigns: %{completed: items}} = socket) when is_list(items) do
    uuid = socket.assigns.uuid
    shown = Enum.take(items, socket.assigns.completed_shown)
    start_async(socket, :completed_posters, fn -> Laev.completed_posters(uuid, shown) end)
  end

  defp fetch_posters(socket), do: socket

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("connect", %{"laev" => p}, socket) do
    key = String.trim(p["key"] || "")
    uuid = socket.assigns.uuid

    if key == "" do
      {:noreply, assign(socket, :error, "Paste your laev key first.")}
    else
      opts = [carry_keys?: p["carry"] == "true", url: p["url"]]

      {:noreply,
       socket
       |> assign(error: nil, busy: "Connecting and pulling your history…")
       |> start_async(:connect, fn -> Laev.connect(uuid, key, opts) end)}
    end
  end

  def handle_event("setup", %{"setup" => p}, socket) do
    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(error: nil, busy: "Checking your keys and setting you up…")
     |> start_async(:connect, fn ->
       case Laev.setup(uuid, Map.take(p, ~w(RD_TOKEN TORBOX_API_KEY TMDB_API_KEY))) do
         :ok -> {:ok, :setup}
         {:error, why} -> {:error, why}
       end
     end)}
  end

  def handle_event("toggle_section", %{"id" => id}, socket) do
    open = socket.assigns.open
    opening? = not MapSet.member?(open, id)

    socket =
      assign(socket, :open, if(opening?, do: MapSet.put(open, id), else: MapSet.delete(open, id)))

    {:noreply, if(opening? and id == "completed", do: fetch_posters(socket), else: socket)}
  end

  # Off the saved list: gone from the page at once, so the rest closes up and it is plain that it
  # was removed.
  def handle_event(
        "unsave",
        %{"type" => type, "id" => id},
        %{assigns: %{data: %{} = data}} = socket
      )
      when type in ["movie", "tv"] do
    case Integer.parse(id) do
      {n, ""} ->
        Roki.Watch.unsave(socket.assigns.uuid, type, n)
        saved = Enum.reject(data.saved, &(&1.type == type and &1.id == n))
        {:noreply, assign(socket, :data, %{data | saved: saved})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("unsave", _params, socket), do: {:noreply, socket}

  def handle_event("more_completed", _params, socket),
    do: {:noreply, socket |> update(:completed_shown, &(&1 + @completed_page)) |> fetch_posters()}

  def handle_event("sync", _params, socket) do
    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(error: nil, busy: "Syncing…")
     |> start_async(:sync, fn -> Laev.sync(uuid) end)}
  end

  # ── async results ──────────────────────────────────────────────────

  @impl true
  def handle_async(:overview, {:ok, :not_connected}, socket),
    do: {:noreply, assign(socket, state: :not_connected, data: nil)}

  # The shelf comes with its progress bars worked out (`Laev.shelf/1`), so nothing is added to it
  # afterwards and nothing changes under the reader's eye when it lands.
  def handle_async(:overview, {:ok, {:ok, data}}, socket),
    do: {:noreply, assign(socket, state: :ready, data: data, busy: nil)}

  def handle_async(:completed, {:ok, items}, socket) when is_list(items),
    do:
      {:noreply,
       socket
       |> assign(:completed, items)
       |> then(&if(MapSet.member?(&1.assigns.open, "completed"), do: fetch_posters(&1), else: &1))}

  def handle_async(:completed, _other, socket), do: {:noreply, socket}

  def handle_async(:completed_posters, {:ok, posters}, %{assigns: %{completed: items}} = socket)
      when is_map(posters) and is_list(items) do
    items =
      Enum.map(items, fn i ->
        if i.poster == nil and posters[{i.type, i.id}],
          do: %{i | poster: posters[{i.type, i.id}]},
          else: i
      end)

    {:noreply, assign(socket, :completed, items)}
  end

  def handle_async(:completed_posters, _other, socket), do: {:noreply, socket}

  def handle_async(:stats, {:ok, {:ok, s}}, socket), do: {:noreply, assign(socket, :stats, s)}

  def handle_async(:stats, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :stats, {:error, reason})}

  def handle_async(:stats, {:exit, _}, socket),
    do: {:noreply, assign(socket, :stats, {:error, :failed})}

  def handle_async(:pulse, {:ok, {:ok, %{events: events}}}, socket),
    do: {:noreply, assign(socket, :pulse, Roki.Calendar.pulse(events))}

  # No release dates is not worth an error on the home page — but the placeholder
  # has to resolve to something, or it would shimmer forever.
  def handle_async(:pulse, _other, socket), do: {:noreply, assign(socket, :pulse, :unavailable)}

  # A refresh that failed behind a shelf that is already on screen leaves the shelf alone: the
  # page is as good as it was a second ago, and an error over it would say otherwise.
  def handle_async(:overview, {:exit, _reason}, %{assigns: %{data: %{}}} = socket),
    do: {:noreply, assign(socket, :busy, nil)}

  def handle_async(:overview, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket,
         state: :not_connected,
         error: "Could not read your shelf: #{inspect(reason)}"
       )}

  def handle_async(:connect, {:ok, {:ok, _summary}}, socket), do: {:noreply, load(socket)}

  def handle_async(:connect, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: nil,
         error:
           if(is_binary(reason), do: reason, else: "Could not connect: " <> Laev.explain(reason))
       )}

  def handle_async(:sync, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: nil, error: "Sync failed: " <> Laev.explain(reason))}

  def handle_async(:sync, {:ok, _}, socket), do: {:noreply, reload(socket)}

  def handle_async(name, {:exit, reason}, socket),
    do: {:noreply, assign(socket, busy: nil, error: "#{name} failed: #{inspect(reason)}")}

  # ── view ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@username}/home"}
    >
      <.connect_card
        :if={@state == :not_connected and not @granted}
        form={@form}
        busy={@busy}
        error={@error}
      />

      <p
        :if={@state == :not_connected and @granted}
        class="flex items-center justify-center gap-3 py-24 text-base-content/60"
      >
        <span :if={@busy} class="loading loading-spinner"></span>
        {@busy || @error || "Setting up your account…"}
      </p>

      <.shelf
        :if={@state in [:loading, :ready]}
        data={@data}
        busy={@busy}
        error={@error}
        open={@open}
        stats={@stats}
        pulse={@pulse}
        completed={@completed}
        completed_shown={@completed_shown}
        ratings={@ratings}
        reading={@reading}
        manga_totals={@manga_totals}
        username={@username}
        cached_titles={@cached_titles}
      />
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :busy, :string, default: nil
  attr :error, :string, default: nil

  defp connect_card(assigns) do
    ~H"""
    <section class="mx-auto max-w-xl space-y-5 py-10">
      <div class="space-y-2 text-center">
        <h1 class="text-2xl font-bold sm:text-3xl">Set up your shelf</h1>
        <p class="text-base-content/70">
          Set up your account here, or bring an existing one from the <code>laev</code> terminal app.
        </p>
      </div>

      <form id="setup-form" phx-submit="setup" class="card bg-base-200 space-y-4 p-6">
        <div>
          <h2 class="text-lg font-semibold">New here? Set up in one step</h2>
          <p class="text-sm text-base-content/60">
            Add your keys and press Set up. Your account, watchlist and settings are created and
            synced for you — you can connect the terminal app afterwards from Settings.
          </p>
        </div>
        <label
          :for={
            {name, label, url, hint} <- [
              {"RD_TOKEN", "Real-Debrid API token", "https://real-debrid.com/apitoken",
               "one of these two"},
              {"TORBOX_API_KEY", "TorBox API key", "https://torbox.app/settings", "one of these two"},
              {"TMDB_API_KEY", "TMDB API key", "https://www.themoviedb.org/settings/api", "required"}
            ]
          }
          class="block"
        >
          <span class="mb-1 flex items-baseline justify-between gap-2 text-sm">
            <span class="font-medium">{label} <span class="text-base-content/50">({hint})</span></span>
            <a
              href={url}
              target="_blank"
              rel="noopener"
              class="text-xs underline text-base-content/60"
            >
              where to get it
            </a>
          </span>
          <input
            type="password"
            name={"setup[#{name}]"}
            autocomplete="off"
            spellcheck="false"
            class="input input-bordered w-full font-mono"
          />
        </label>
        <p :if={@error} class="alert alert-error text-sm">{@error}</p>
        <button type="submit" class="btn btn-primary" disabled={@busy != nil}>
          <span :if={@busy} class="loading loading-spinner loading-sm"></span>
          {@busy || "Set up"}
        </button>
      </form>

      <p class="text-center text-sm text-base-content/60">
        Already use the laev terminal app? Paste its key instead:
      </p>

      <.form for={@form} id="connect-form" phx-submit="connect" class="card bg-base-200 space-y-4 p-6">
        <label class="form-control w-full">
          <span class="label-text mb-1 font-medium">Your laev key</span>
          <input
            type="password"
            name="laev[key]"
            value={@form[:key].value}
            placeholder="laev_….…"
            autocomplete="off"
            spellcheck="false"
            class="input input-bordered w-full font-mono"
          />
          <span class="label-text-alt mt-1 text-base-content/60">
            <code>laev sync</code> → "show my laev key" in the terminal app.
          </span>
        </label>

        <label class="flex cursor-pointer items-start gap-3">
          <input type="hidden" name="laev[carry]" value="false" />
          <input type="checkbox" name="laev[carry]" value="true" class="checkbox mt-0.5" />
          <span class="text-sm">
            <span class="font-medium">Also bring my API keys</span>
            (Real-Debrid / TorBox / TMDB).
            <span class="text-base-content/60">
              Needed to resolve streams and show full titles. They are decrypted here and stored on
              this server for your account only. Leave off to bring just your history.
            </span>
          </span>
        </label>

        <details class="text-sm">
          <summary class="cursor-pointer text-base-content/60">Sync server (advanced)</summary>
          <input
            type="url"
            name="laev[url]"
            value={@form[:url].value}
            placeholder="https://roki.ee/api/laev (default)"
            class="input input-bordered input-sm mt-2 w-full"
          />
        </details>

        <button type="submit" class="btn btn-primary" disabled={@busy != nil}>
          <span :if={@busy} class="loading loading-spinner loading-sm"></span>
          {@busy || "Connect"}
        </button>
      </.form>
    </section>
    """
  end

  # "Alice in Borderland S3E4 drops in 3 days" — the next things from the Saved list,
  # from the calendar. One line of reserved height in every state (placeholder, note,
  # "nothing this week", unavailable), so it appearing never moves the page.
  attr :pulse, :any, default: nil
  attr :username, :string, required: true

  defp pulse_line(assigns) do
    {dropped, upcoming} =
      case assigns.pulse do
        {dropped, upcoming} -> {dropped, upcoming}
        _ -> {[], []}
      end

    assigns =
      assign(assigns,
        dropped: dropped,
        upcoming: upcoming,
        next: List.first(upcoming),
        loaded?: is_tuple(assigns.pulse)
      )

    ~H"""
    <div class="min-h-4 text-xs">
      <div :if={@pulse == nil} class="skeleton h-3 w-72 max-w-full rounded"></div>
      <.link
        :if={@loaded? and (@next || @dropped != [])}
        navigate={~p"/#{@username}/calendar"}
        class="flex items-start gap-1.5 text-base-content/60 transition hover:text-base-content"
      >
        <.icon name="hero-calendar-days" class="mt-px h-3.5 w-3.5 shrink-0" />
        <span class="min-w-0">
          <span :if={@next}>
            <span class="text-base-content/80">{@next.label}</span>
            drops {Roki.Calendar.relative(@next.days)}<span :if={length(@upcoming) > 1}> · +{length(
              @upcoming
            ) - 1} more this week</span>
          </span>
          <span :if={@next && @dropped != []} class="hidden sm:inline"> · </span>
          <span :if={@dropped != []} class={[@next && "hidden sm:inline"]}>
            just dropped: {@dropped |> Enum.take(2) |> Enum.map_join(", ", & &1.label)}<span :if={
              length(@dropped) > 2
            }> +{length(@dropped) - 2}</span>
          </span>
        </span>
      </.link>
      <.link
        :if={@loaded? and !@next and @dropped == []}
        navigate={~p"/#{@username}/calendar"}
        class="flex items-start gap-1.5 text-base-content/40 transition hover:text-base-content/70"
      >
        <.icon name="hero-calendar-days" class="mt-px h-3.5 w-3.5 shrink-0" />
        <span>Nothing dropping from your Saved list this week</span>
      </.link>
    </div>
    """
  end

  # A grey bar the size of the text it stands in for.
  attr :class, :string, default: ""

  defp sk(assigns),
    do: ~H|<span class={["skeleton h-5 origin-center scale-y-75 rounded", @class]}></span>|

  attr :data, :any,
    default: nil,
    doc: "nil while the shelf is loading: the page draws placeholders"

  attr :busy, :string, default: nil
  attr :error, :string, default: nil
  attr :open, :any, default: nil
  attr :stats, :any, default: nil
  attr :pulse, :any, default: nil
  attr :completed, :any, default: nil
  attr :completed_shown, :integer, default: 100
  attr :ratings, :map, default: %{}
  attr :reading, :any, default: nil, doc: "the one manga to carry on with, if any"
  attr :manga_totals, :map, default: %{seconds: 0, series: 0, chapters: 0}
  attr :username, :string, required: true
  attr :cached_titles, :any, default: nil

  defp shelf(assigns) do
    assigns =
      assign(assigns, :watching, assigns.data && List.first(assigns.data.watchlist.behind))

    ~H"""
    <div class="space-y-10">
      <%!-- Stats and the release note: small, quiet, and the same size whether loaded or
            not — placeholders stand in at their width, and what is known at once comes
            first, so numbers arriving later only ever fill space already reserved. --%>
      <div class="space-y-1.5">
        <div class="flex items-start gap-1">
          <%!-- Every figure sits in a cell of its own, so a figure arriving at a different width
                than its placeholder cannot push anything it does not have to.

                On a phone the cells are a two-column grid: each one can only change the inside
                of itself.

                From `sm` up they are one wrapping row, and it is kept compact rather than
                reserved: the reading pair is pinned to the right end of the row by an automatic
                margin, so it stays where it is whatever the cells before it turn out to be, and
                the placeholders are sized like the figures they stand for. (Reserving room for the
                widest a figure could ever be made the row wrap on an ordinary laptop, and sent
                "all stats" to a second line.) "All stats" is not in the row at all: a link inside
                a wrapping row is the first thing to drop when the figures are wide. --%>
          <.link
            navigate={~p"/#{@username}/stats"}
            class="grid min-h-5 min-w-0 flex-1 grid-cols-2 items-center gap-x-4 gap-y-1 text-sm tabular-nums text-base-content/60 transition hover:text-base-content sm:flex sm:flex-wrap sm:gap-y-0.5"
          >
            <span :if={@data} class="whitespace-nowrap">
              <b class="text-base-content">{@data.tally.behind}</b> in progress
            </span>
            <span :if={@data} class="whitespace-nowrap">
              <b class="text-base-content">{@data.tally.series_finished + @data.tally.anime_finished}</b>
              <span class="sm:hidden">finished</span>
              <span class="hidden sm:inline">series &amp; anime finished</span>
            </span>
            <%!-- The placeholders are about as wide as the figures usually are, so the row comes out the
                 same shape with them in it as with the figures. --%>
            <span :if={!@data} class="block"><.sk class="block w-[5.7rem]" /></span>
            <span :if={!@data} class="block"><.sk class="block w-[4rem] sm:w-[10.9rem]" /></span>

            <%= cond do %>
              <% match?(%{totals: _}, @stats) -> %>
                <span class="whitespace-nowrap">
                  <b class="text-base-content">{Roki.Laev.duration(@stats.totals.seconds)}</b> watched
                </span>
                <span class="whitespace-nowrap">
                  <b class="text-base-content">{thousands(@stats.totals.films)}</b> films watched
                </span>
                <span class="hidden whitespace-nowrap sm:inline">
                  <b class="text-base-content">{thousands(@stats.totals.episodes)}</b> episodes
                </span>
              <% match?({:error, _}, @stats) -> %>
                <span class="col-span-2 text-base-content/40 sm:col-span-1">
                  time watched unavailable
                </span>
              <% true -> %>
                <span class="block"><.sk class="block w-[8.1rem]" /></span>
                <span class="block"><.sk class="block w-[7.9rem]" /></span>
                <span class="hidden sm:block"><.sk class="block w-[6.1rem]" /></span>
            <% end %>

            <%!-- Reading: known from the first paint, and on desktop pinned to the right end of
                 the row so the figures before it cannot move it. --%>
            <span
              :if={@manga_totals.series > 0}
              class="whitespace-nowrap sm:ml-auto"
            >
              <b class="text-base-content">{Roki.Laev.duration(@manga_totals.seconds)}</b> read
            </span>
            <span
              :if={@manga_totals.chapters > 0}
              class={[
                "hidden whitespace-nowrap sm:inline",
                @manga_totals.series == 0 && "sm:ml-auto"
              ]}
            >
              <b class="text-base-content">{thousands(@manga_totals.chapters)}</b> chapters
            </span>
          </.link>
          <.link
            navigate={~p"/#{@username}/stats"}
            class="hidden h-5 shrink-0 items-center whitespace-nowrap px-1 text-xs text-base-content/50 transition hover:text-base-content sm:flex"
          >
            all stats →
          </.link>
          <%!-- Sync is a small icon at the end of the line; it spins while it works. --%>
          <button
            type="button"
            phx-click="sync"
            class="btn btn-ghost btn-xs btn-square shrink-0"
            title={@busy || "Sync now"}
            aria-label="Sync now"
            disabled={@busy != nil or @data == nil}
          >
            <.icon
              name="hero-arrow-path"
              class={if @busy, do: "h-4 w-4 animate-spin", else: "h-4 w-4"}
            />
          </button>
        </div>
        <.pulse_line pulse={@pulse} username={@username} />
        <p :if={@error} class="alert alert-error mt-2 text-sm">{@error}</p>
      </div>

      <%!-- Where you are, in one row: the chapter you stopped on, and the episode you are up
            to. Two things, not two shelves — the lists below are for browsing, this is for
            carrying on. --%>
      <section :if={@reading || @watching || @data == nil} class="space-y-3">
        <h2 class="text-xl font-semibold">Continue</h2>
        <%!-- Two across at every width: on a phone they are what the page opens with, and one
              above the other would push the lists past the fold. --%>
        <div class="grid grid-cols-2 gap-3">
          <a
            :if={@reading}
            href={~p"/manga/#{@reading.source}/#{@reading.slug}/#{@reading.last_chapter}"}
            class="flex gap-3 rounded-box border border-base-300 p-3 transition hover:bg-base-200"
          >
            <img
              :if={manga_cover(@reading)}
              src={manga_cover(@reading)}
              alt={@reading.title}
              class="hidden h-24 w-16 shrink-0 rounded object-cover min-[380px]:block"
            />
            <span class="min-w-0 self-center">
              <span class="block text-xs uppercase tracking-wide text-base-content/50">Reading</span>
              <span class="block truncate font-semibold">{@reading.title}</span>
              <span class="block text-sm text-base-content/60">
                Chapter {@reading.last_chapter}
              </span>
            </span>
          </a>
          <.link
            :if={@watching}
            navigate={href(@watching)}
            class="flex gap-3 rounded-box border border-base-300 p-3 transition hover:bg-base-200"
          >
            <img
              :if={@watching.poster}
              src={Roki.Images.local(@watching.poster)}
              alt={@watching.title}
              class="hidden h-24 w-16 shrink-0 rounded object-cover min-[380px]:block"
            />
            <span class="min-w-0 self-center">
              <span class="block text-xs uppercase tracking-wide text-base-content/50">Watching</span>
              <span class="block truncate font-semibold">{@watching.title}</span>
              <span :if={@watching[:note]} class="block text-sm text-base-content/60">
                {@watching.note}
              </span>
            </span>
          </.link>
          <%!-- Watching comes from laev, which answers a moment after the page does. Without
                this the right half is empty and then a card appears out of nowhere; with it the
                place is held in the card's own shape. --%>
          <div
            :if={@data == nil}
            class="flex gap-3 rounded-box border border-base-300 p-3"
            aria-busy="true"
          >
            <div class="skeleton hidden h-24 w-16 shrink-0 rounded min-[380px]:block"></div>
            <div class="min-w-0 flex-1 space-y-2 self-center">
              <div class="skeleton h-3 w-16 rounded"></div>
              <div class="skeleton h-4 w-full rounded"></div>
              <div class="skeleton h-3 w-2/3 rounded"></div>
            </div>
          </div>
        </div>
      </section>

      <.no_data_yet :if={@data && @completed == [] && empty_shelf?(@data)} />

      <%!-- Watchlist placeholder: the same grid the real one fills, so nothing moves. --%>
      <section :if={!@data} class="space-y-3" aria-busy="true">
        <div class="skeleton h-7 w-40 rounded"></div>
        <ul class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
          <li :for={_ <- 1..16} class="space-y-1">
            <div class="skeleton aspect-[2/3] w-full rounded-box"></div>
            <div class="skeleton h-5 w-3/4 rounded"></div>
            <div class="skeleton h-4 w-1/2 rounded"></div>
          </li>
        </ul>
      </section>

      <.poster_row
        :if={@data}
        title="Watchlist"
        count={length(@data.watchlist.behind)}
        items={@data.watchlist.behind}
        empty="Nothing in progress. Start something and it waits here for you to pick it up."
        cached_titles={@cached_titles}
      />
      <.fold
        :if={@data}
        id="saved"
        title="Saved"
        items={@data.saved}
        empty="Nothing saved yet. Hover a poster and press the bookmark to keep it for later."
        unsave
        open={@open}
        cached_titles={@cached_titles}
      />
      <.fold
        :if={@data}
        id="caught_up"
        title="Caught up"
        items={@data.watchlist.caught_up}
        empty="Shows where you have seen every episode so far wait here for the next one."
        open={@open}
        cached_titles={@cached_titles}
      />
      <.fold
        :if={@data}
        id="on_hold"
        title="On hold"
        items={@data.watchlist.on_hold}
        empty="Put a show on hold from its page and it rests here, out of your way."
        open={@open}
        cached_titles={@cached_titles}
      />
      <.fold
        :if={@data}
        id="history"
        title="History"
        items={@data.continue}
        empty="What you start watching shows up here."
        open={@open}
        cached_titles={@cached_titles}
      />
      <.completed
        :if={@data && @completed != nil}
        items={@completed}
        shown={@completed_shown}
        open={MapSet.member?(@open, "completed")}
        ratings={@ratings}
        cached_titles={@cached_titles}
      />
    </div>
    """
  end

  defp empty_shelf?(data) do
    data.watchlist.behind == [] and data.watchlist.caught_up == [] and
      data.watchlist.on_hold == [] and data.saved == [] and data.continue == []
  end

  # An account with nothing yet: say so, and point at where things come from.
  defp no_data_yet(assigns) do
    ~H"""
    <section class="rounded-box border border-dashed border-base-300 px-5 py-6 text-center">
      <h2 class="text-lg font-semibold">No data yet</h2>
      <p class="mx-auto mt-1 max-w-md text-sm text-base-content/60">
        Watch something and this page fills in — what you are in the middle of, what you saved, what you
        finished. Pick a place to start:
      </p>
      <div class="mt-4 flex flex-wrap justify-center gap-2">
        <.link navigate={~p"/home"} class="btn btn-primary btn-sm">Featured</.link>
        <.link navigate={~p"/movies"} class="btn btn-sm">Movies</.link>
        <.link navigate={~p"/shows"} class="btn btn-sm">Shows</.link>
        <.link navigate={~p"/anime"} class="btn btn-sm">Anime</.link>
      </div>
    </section>
    """
  end

  # A section that starts closed and draws nothing — no posters, so no image
  # requests — until it is opened. Open state lives on the server.
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :open, :any, required: true
  attr :cached_titles, :any, default: nil

  attr :unsave, :boolean,
    default: false,
    doc: "a button on each poster that takes it off the list"

  attr :empty, :string,
    default: nil,
    doc: "what to say, once opened, while there is nothing in it"

  defp fold(assigns) do
    assigns = assign(assigns, :shown, MapSet.member?(assigns.open, assigns.id))

    ~H"""
    <section class="space-y-3">
      <button
        phx-click="toggle_section"
        phx-value-id={@id}
        aria-expanded={to_string(@shown)}
        class={[
          "flex cursor-pointer items-center gap-2 text-xl font-semibold",
          @items == [] && "text-base-content/60"
        ]}
      >
        <.icon
          name="hero-chevron-right"
          class={["h-4 w-4 transition", @shown && "rotate-90"]}
        />
        {@title}
        <span class="text-sm font-normal text-base-content/60">{length(@items)}</span>
      </button>
      <p :if={@shown and @items == [] and @empty} class="text-sm text-base-content/50">{@empty}</p>
      <ul
        :if={@shown and @items != []}
        class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8"
      >
        <li :for={i <- @items} class="space-y-1">
          <.poster item={i} cached_titles={@cached_titles} compact title?={false} />
          <%!-- No badge: everything here is saved. Taking a title off in its hover card clicks this
                to drop the tile (assets/js/peek.js), so the list closes up without a refresh. --%>
          <button
            :if={@unsave}
            type="button"
            class="hidden"
            tabindex="-1"
            aria-hidden="true"
            phx-click="unsave"
            phx-value-type={i.type}
            phx-value-id={i.id}
          ></button>
        </li>
      </ul>
    </section>
    """
  end

  # Everything the user has finished, newest first, a month at a time: a place to go back in
  # time and see what they were watching then. Closed until opened, like the other folds, so
  # its posters cost nothing until wanted; a hundred rows per page.
  attr :items, :list, required: true
  attr :shown, :integer, required: true
  attr :open, :boolean, required: true
  attr :ratings, :map, default: %{}
  attr :cached_titles, :any, default: nil

  defp completed(assigns) do
    page = Enum.take(assigns.items, assigns.shown)

    assigns =
      assign(assigns,
        groups: Enum.chunk_by(page, &month_of/1),
        more: length(assigns.items) - length(page)
      )

    ~H"""
    <section class="space-y-3" id="completed">
      <button
        phx-click="toggle_section"
        phx-value-id="completed"
        aria-expanded={to_string(@open)}
        class={[
          "flex cursor-pointer items-center gap-2 text-xl font-semibold",
          @items == [] && "text-base-content/60"
        ]}
      >
        <.icon name="hero-chevron-right" class={["h-4 w-4 transition", @open && "rotate-90"]} />
        Completed <span class="text-sm font-normal text-base-content/60">{length(@items)}</span>
      </button>
      <p :if={@open and @items == []} class="text-sm text-base-content/50">
        Everything you finish watching is kept here, newest first.
      </p>
      <div :if={@open and @items != []} class="space-y-6">
        <div :for={group <- @groups} class="space-y-2">
          <h3 class="text-sm font-medium text-base-content/60">{month_label(hd(group))}</h3>
          <ul class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
            <li :for={i <- group} class="space-y-1">
              <.poster item={i} cached_titles={@cached_titles} compact title?={false} />
              <% score = Roki.Profile.score_for(@ratings, i) %>
              <div
                :if={i.dated? or score != nil}
                class="flex items-center justify-between text-xs text-base-content/50"
              >
                <span>{if i.dated?, do: day_label(i)}</span>
                <span :if={score != nil} class="font-semibold text-warning">★ {Roki.Profile.score_text(
                  score
                )}</span>
              </div>
            </li>
          </ul>
        </div>
        <button :if={@more > 0} phx-click="more_completed" class="btn btn-ghost btn-sm">
          Show {min(@more, 100)} more
        </button>
      </div>
    </section>
    """
  end

  @months ~w(January February March April May June July August September October November December)

  defp month_of(%{dated?: true, at: at}) do
    d = DateTime.from_unix!(at)
    {d.year, d.month}
  end

  defp month_of(_), do: :undated

  defp month_label(item) do
    case month_of(item) do
      {y, m} -> "#{Enum.at(@months, m - 1)} #{y}"
      :undated -> "No date"
    end
  end

  defp day_label(%{at: at}) do
    d = DateTime.from_unix!(at)
    "#{String.slice(Enum.at(@months, d.month - 1), 0, 3)} #{d.day}"
  end

  # The media library's copy when there is one, else the source's own address through this
  # site, which carries the headers the source asks for.
  defp manga_cover(%{cover_file_uuid: uuid}) when is_binary(uuid) and uuid != "",
    do: PhoenixKit.Modules.Storage.URLSigner.signed_url(uuid, "medium")

  defp manga_cover(%{cover_url: url}) when is_binary(url) and url != "",
    do: ~p"/manga/proxy/image?#{%{url: url}}"

  defp manga_cover(_), do: nil

  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :cached_titles, :any, default: nil
  attr :items, :list, required: true
  attr :empty, :string, default: nil, doc: "what to say while there is nothing in it"

  defp poster_row(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class={["text-xl font-semibold", @items == [] && "text-base-content/60"]}>
        {@title}
        <span class="text-sm font-normal text-base-content/60">{@count}</span>
      </h2>
      <p :if={@items == [] and @empty} class="text-sm text-base-content/50">{@empty}</p>
      <ul
        :if={@items != []}
        class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8"
      >
        <li :for={i <- @items} class="space-y-1">
          <.poster item={i} cached_titles={@cached_titles} compact title?={false} />
        </li>
      </ul>
    </section>
    """
  end

  defp thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp thousands(n), do: to_string(n)
end
