defmodule RokiWeb.HomeLive do
  @moduledoc """
  The home page of a watching site.

  A visitor sees the pitch and the PhoenixKit menu (log in / register). A
  signed-in user sees their own shelf — but only once they have *chosen* to
  connect laev: pasting their laev key pulls their watchlist, resume points,
  history and settings in from wherever that key syncs. Nothing about laev
  happens at sign-up, and accounts are never linked to each other.
  """
  use RokiWeb, :live_view

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Laev

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    uuid = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)

    socket =
      socket
      |> assign(:page_title, "Home")
      |> assign(:uuid, uuid)
      |> assign(:state, if(uuid, do: :loading, else: :visitor))
      |> assign(:data, nil)
      |> assign(:busy, nil)
      |> assign(:error, nil)
      |> assign(:form, to_form(%{"key" => "", "url" => "", "carry" => "false"}, as: :laev))

    {:ok, if(connected?(socket) && uuid, do: load(socket), else: socket)}
  end

  defp load(socket) do
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

  def handle_async(:overview, {:ok, {:ok, data}}, socket),
    do: {:noreply, assign(socket, state: :ready, data: data, busy: nil)}

  def handle_async(:overview, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket,
         state: :not_connected,
         error: "Could not read your shelf: #{inspect(reason)}"
       )}

  def handle_async(:connect, {:ok, {:ok, _summary}}, socket),
    do: {:noreply, load(assign(socket, :state, :loading))}

  def handle_async(:connect, {:ok, {:error, reason}}, socket),
    do:
      {:noreply, assign(socket, busy: nil, error: "Could not connect: " <> Laev.explain(reason))}

  def handle_async(:sync, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: nil, error: "Sync failed: " <> Laev.explain(reason))}

  def handle_async(:sync, {:ok, _}, socket),
    do: {:noreply, load(assign(socket, :state, :loading))}

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
      current_path="/"
    >
      <.visitor :if={@state == :visitor} />

      <div
        :if={@state == :loading}
        class="flex items-center gap-3 py-24 justify-center text-base-content/60"
      >
        <span class="loading loading-spinner"></span> Loading your shelf…
      </div>

      <.connect_card :if={@state == :not_connected} form={@form} busy={@busy} error={@error} />

      <.shelf :if={@state == :ready} data={@data} busy={@busy} error={@error} />
    </Layouts.app>
    """
  end

  defp visitor(assigns) do
    ~H"""
    <section class="hero py-16">
      <div class="hero-content text-center">
        <div class="max-w-xl space-y-5">
          <h1 class="text-5xl font-bold tracking-tight">Everything you watch, in one place.</h1>
          <p class="text-lg text-base-content/70">
            Films, shows and anime — your watchlist, where you stopped and how much you have seen,
            following you from the terminal to the browser.
          </p>
          <div class="flex justify-center gap-3">
            <a href="/phoenix_kit/users/register" class="btn btn-primary">Create an account</a>
            <a href="/phoenix_kit/users/log-in" class="btn btn-ghost">Log in</a>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :busy, :string, default: nil
  attr :error, :string, default: nil

  defp connect_card(assigns) do
    ~H"""
    <section class="mx-auto max-w-xl space-y-5 py-10">
      <div class="space-y-2 text-center">
        <h1 class="text-3xl font-bold">Connect laev</h1>
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
          <input type="checkbox" name="laev[carry]" value="true" class="checkbox checkbox-sm mt-1" />
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

  attr :data, :map, required: true
  attr :busy, :string, default: nil
  attr :error, :string, default: nil

  defp shelf(assigns) do
    ~H"""
    <div class="space-y-10">
      <div class="flex flex-wrap items-center gap-3">
        <h1 class="mr-auto text-3xl font-bold tracking-tight">Your shelf</h1>
        <span :if={@busy} class="flex items-center gap-2 text-sm text-base-content/60">
          <span class="loading loading-spinner loading-sm"></span> {@busy}
        </span>
        <button phx-click="sync" class="btn btn-sm" disabled={@busy != nil}>
          <.icon name="hero-arrow-path" class="h-4 w-4" /> Sync now
        </button>
        <button
          phx-click="disconnect"
          data-confirm="Disconnect laev and delete everything pulled for this account? Your laev key's server keeps its copy."
          class="btn btn-sm btn-ghost"
        >
          Disconnect
        </button>
      </div>

      <p :if={@error} class="alert alert-error text-sm">{@error}</p>

      <div class="stats stats-vertical sm:stats-horizontal w-full bg-base-200 shadow-sm">
        <div class="stat">
          <div class="stat-title">Time watched</div>
          <div class="stat-value text-2xl">{Roki.Laev.duration(@data.stats.seconds)}</div>
          <div class="stat-desc">
            films &amp; tv {Roki.Laev.duration(@data.stats.other.seconds)} · anime {Roki.Laev.duration(
              @data.stats.anime.seconds
            )}
          </div>
        </div>
        <div class="stat">
          <div class="stat-title">Films</div>
          <div class="stat-value text-2xl">{@data.stats.films}</div>
          <div class="stat-desc">{@data.stats.episodes} episodes from {@data.stats.shows} shows</div>
        </div>
        <div class="stat">
          <div class="stat-title">In progress</div>
          <div class="stat-value text-2xl">{@data.tally.behind}</div>
          <div class="stat-desc">{@data.tally.caught_up} caught up · {@data.tally.held} on hold</div>
        </div>
        <div class="stat">
          <div class="stat-title">Finished</div>
          <div class="stat-value text-2xl">
            {@data.tally.series_finished + @data.tally.anime_finished}
          </div>
          <div class="stat-desc">
            {@data.tally.series_finished} series · {@data.tally.anime_finished} anime
          </div>
        </div>
      </div>

      <.poster_row title="Watchlist" items={@data.saved} />
      <.poster_row title="History" items={@data.continue} />

      <section class="space-y-3">
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
        </div>
      </section>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, required: true

  defp poster_row(assigns) do
    ~H"""
    <section :if={@items != []} class="space-y-3">
      <h2 class="text-xl font-semibold">{@title}</h2>
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

  defp subtitle(%{season: s, episode: e}) when is_integer(s) and is_integer(e),
    do: "S#{s} · E#{e}"

  defp subtitle(%{episode: e}) when is_integer(e), do: "Episode #{e}"
  defp subtitle(%{year: y}) when is_binary(y) and y != "", do: y
  defp subtitle(%{type: "movie"}), do: "Film"
  defp subtitle(%{type: "tv"}), do: "Series"
  defp subtitle(_), do: ""
end
