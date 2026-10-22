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

        socket =
          socket
          |> assign(:page_title, "Home")
          |> assign(:username, username)
          |> assign(:uuid, uuid)
          |> assign(:state, if(Laev.connected?(uuid), do: :loading, else: :not_connected))
          |> assign(:data, nil)
          |> assign(:busy, nil)
          |> assign(:error, nil)
          |> assign(:open, MapSet.new())
          |> assign(:stats, nil)
          |> assign(:pulse, nil)
          |> assign(:client, RokiWeb.Client.key(socket, uuid))
          |> assign(:form, to_form(%{"key" => "", "url" => "", "carry" => "false"}, as: :laev))

        {:ok,
         if(connected?(socket) and socket.assigns.state == :loading,
           do: load(socket),
           else: socket
         )}
    end
  end

  defp same_user?(mine, requested) when is_binary(mine),
    do: String.downcase(mine) == String.downcase(requested)

  defp same_user?(_, _), do: false

  # First load / after connecting: the skeleton shows until the shelf arrives.
  defp load(socket) do
    socket |> assign(state: :loading, data: nil, stats: nil, pulse: nil) |> reload()
  end

  # A refresh (sync): the page stays exactly as it is and the new data replaces the
  # old in place — nothing blanks, nothing moves.
  defp reload(socket) do
    uuid = socket.assigns.uuid
    start_async(socket, :overview, fn -> Laev.overview(uuid) end)
  end

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

  def handle_event("toggle_section", %{"id" => id}, socket) do
    open = socket.assigns.open

    {:noreply,
     assign(
       socket,
       :open,
       if(MapSet.member?(open, id), do: MapSet.delete(open, id), else: MapSet.put(open, id))
     )}
  end

  def handle_event("sync", _params, socket) do
    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(error: nil, busy: "Syncing…")
     |> start_async(:sync, fn -> Laev.sync(uuid) end)}
  end

  def handle_event("toggle_keys", _params, socket) do
    uuid = socket.assigns.uuid
    on? = not socket.assigns.data.keys_carried?

    {:noreply,
     socket
     |> assign(error: nil, busy: "Updating…")
     |> start_async(:sync, fn -> Laev.set_carry_keys(uuid, on?) end)}
  end

  def handle_event("disconnect", _params, socket) do
    :ok = Laev.disconnect(socket.assigns.uuid)
    {:noreply, assign(socket, state: :not_connected, data: nil, error: nil, busy: nil)}
  end

  # ── async results ──────────────────────────────────────────────────

  @impl true
  def handle_async(:overview, {:ok, :not_connected}, socket),
    do: {:noreply, assign(socket, state: :not_connected, data: nil)}

  # The shelf is on screen first; what costs lookups (stats, release dates) follows
  # and fills in its own corner.
  def handle_async(:overview, {:ok, {:ok, data}}, socket) do
    %{uuid: uuid, client: client} = socket.assigns

    {:noreply,
     socket
     |> assign(state: :ready, data: data, busy: nil)
     |> start_async(:stats, fn -> Roki.Stats.summary(uuid) end)
     |> start_async(:pulse, fn -> Roki.Calendar.load(client, uuid) end)}
  end

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
      {:noreply, assign(socket, busy: nil, error: "Could not connect: " <> Laev.explain(reason))}

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
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@username}/home"}
    >
      <.connect_card :if={@state == :not_connected} form={@form} busy={@busy} error={@error} />

      <.shelf
        :if={@state in [:loading, :ready]}
        data={@data}
        busy={@busy}
        error={@error}
        open={@open}
        stats={@stats}
        pulse={@pulse}
        username={@username}
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
        <h1 class="text-2xl font-bold sm:text-3xl">Connect laev</h1>
        <p class="text-base-content/70">
          Already use the <code>laev</code> terminal app? Paste your laev key and your watchlist,
          history and settings are pulled in here. It's optional — your account works without it.
        </p>
      </div>

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
            placeholder="https://sasha.don.ee/laev (default)"
            class="input input-bordered input-sm mt-2 w-full"
          />
        </details>

        <p :if={@error} class="alert alert-error text-sm">{@error}</p>

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
  attr :username, :string, required: true

  defp shelf(assigns) do
    ~H"""
    <div class="space-y-10">
      <%!-- Stats and the release note: small, quiet, and the same size whether loaded or
            not — placeholders stand in at their width, and what is known at once comes
            first, so numbers arriving later only ever fill space already reserved. --%>
      <div class="space-y-1.5">
        <div class="flex items-center gap-1">
          <.link
            navigate={~p"/#{@username}/stats"}
            class="flex min-h-5 min-w-0 flex-1 flex-wrap items-center gap-x-4 gap-y-0.5 text-sm text-base-content/60 transition hover:text-base-content"
          >
            <span :if={@data}>
              <b class="text-base-content">{@data.tally.behind}</b> in progress
            </span>
            <span :if={@data}>
              <b class="text-base-content">{@data.tally.series_finished + @data.tally.anime_finished}</b>
              finished
            </span>
            <.sk :if={!@data} class="w-[5.5rem]" />
            <.sk :if={!@data} class="w-[4.5rem]" />

            <%= cond do %>
              <% match?(%{totals: _}, @stats) -> %>
                <span>
                  <b class="text-base-content">{Roki.Laev.duration(@stats.totals.seconds)}</b> watched
                </span>
                <span class="hidden sm:inline">
                  <b class="text-base-content">{@stats.totals.films}</b> films
                </span>
                <span class="hidden sm:inline">
                  <b class="text-base-content">{@stats.totals.episodes}</b> episodes
                </span>
              <% match?({:error, _}, @stats) -> %>
                <span class="text-base-content/40">time watched unavailable</span>
              <% true -> %>
                <.sk class="w-[7.5rem]" />
                <.sk class="hidden w-16 sm:block" />
                <.sk class="hidden w-24 sm:block" />
            <% end %>

            <span class="ml-auto hidden h-5 items-center text-xs text-base-content/50 sm:flex">all stats →</span>
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
      />
      <.fold :if={@data} id="saved" title="Saved" items={@data.saved} open={@open} />
      <.fold
        :if={@data}
        id="caught_up"
        title="Caught up"
        items={@data.watchlist.caught_up}
        open={@open}
      />
      <.fold :if={@data} id="on_hold" title="On hold" items={@data.watchlist.on_hold} open={@open} />
      <.fold :if={@data} id="history" title="History" items={@data.continue} open={@open} />

      <section :if={@data} class="space-y-3">
        <h2 class="text-xl font-semibold">Connections</h2>
        <div class="card bg-base-200 p-4">
          <dl class="grid gap-x-8 gap-y-1 text-sm sm:grid-cols-2 lg:grid-cols-3">
            <div :for={e <- @data.keys} class="flex justify-between gap-4">
              <dt class="text-base-content/70">{e.label}</dt>
              <dd class={["font-mono", !e.set? && "text-base-content/40"]}>
                {if e.set?, do: "connected", else: "not set"}
              </dd>
            </div>
          </dl>
        </div>
        <p class="text-sm text-base-content/60">
          A laev key carries your history and, if you choose, your API keys. Preferences such as the
          player or audio language stay on each device, so they are not shown here.
        </p>

        <div class="flex flex-wrap items-center gap-3 text-sm text-base-content/70">
          <span>
            Syncing with <code>{@data.server}</code>.
            API keys are {if @data.keys_carried?, do: "carried to this account", else: "not carried"}.
          </span>
          <button phx-click="toggle_keys" class="btn btn-xs" disabled={@busy != nil}>
            {if @data.keys_carried?, do: "Stop carrying keys", else: "Bring my API keys"}
          </button>
          <button
            phx-click="disconnect"
            data-confirm="Disconnect laev and delete everything pulled for this account? Your laev key's server keeps its copy."
            class="btn btn-xs btn-ghost text-error"
          >
            Disconnect laev
          </button>
        </div>
      </section>
    </div>
    """
  end

  # A section that starts closed and draws nothing — no posters, so no image
  # requests — until it is opened. Open state lives on the server.
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :open, :any, required: true

  defp fold(assigns) do
    assigns = assign(assigns, :shown, MapSet.member?(assigns.open, assigns.id))

    ~H"""
    <section :if={@items != []} class="space-y-3">
      <button
        phx-click="toggle_section"
        phx-value-id={@id}
        aria-expanded={to_string(@shown)}
        class="flex cursor-pointer items-center gap-2 text-xl font-semibold"
      >
        <.icon
          name="hero-chevron-right"
          class={["h-4 w-4 transition", @shown && "rotate-90"]}
        />
        {@title}
        <span class="text-sm font-normal text-base-content/60">{length(@items)}</span>
      </button>
      <ul :if={@shown} class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
        <li :for={i <- @items} class="space-y-1">
          <.poster item={i} />
        </li>
      </ul>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :items, :list, required: true

  defp poster_row(assigns) do
    ~H"""
    <section :if={@items != []} class="space-y-3">
      <h2 class="text-xl font-semibold">
        {@title}
        <span :if={@count} class="text-sm font-normal text-base-content/60">{@count}</span>
      </h2>
      <ul class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
        <li :for={i <- @items} class="group space-y-1">
          <div class="aspect-[2/3] overflow-hidden rounded-box bg-base-300 shadow">
            <img
              :if={i.poster}
              src={i.poster}
              alt={i.title}
              loading="lazy"
              class="h-full w-full object-cover transition group-hover:scale-105"
            />
            <div
              :if={!i.poster}
              class="flex h-full items-center justify-center p-2 text-center text-xs"
            >
              {i.title}
            </div>
          </div>
          <div class="truncate text-sm font-medium" title={i.title}>{i.title}</div>
          <div class="text-xs text-base-content/60">{subtitle(i)}</div>
        </li>
      </ul>
    </section>
    """
  end
end
