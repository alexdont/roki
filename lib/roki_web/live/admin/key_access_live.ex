defmodule RokiWeb.Admin.KeyAccessLive do
  @moduledoc """
  The admin page "API access": which accounts use the owner's API keys (lent without the account
  ever seeing them — see `Roki.Keys`), which keys are lent, a daily play cap per account, and what
  each account has used — who is heaviest, who is idle.
  """
  use RokiWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Keys

  @labels %{
    "RD_TOKEN" => "Real-Debrid",
    "TORBOX_API_KEY" => "TorBox",
    "TMDB_API_KEY" => "TMDB",
    "OPENSUBTITLES_API_KEY" => "OpenSubtitles key",
    "OPENSUBTITLES_USERNAME" => "OpenSubtitles user",
    "OPENSUBTITLES_PASSWORD" => "OpenSubtitles password",
    "JIMAKU_API_KEY" => "Jimaku"
  }

  @kind_labels [
    {"search", "searches"},
    {"probe", "releases checked"},
    {"play", "plays"},
    {"subtitle", "subtitle downloads"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    me = Scope.user_uuid(socket.assigns[:phoenix_kit_current_scope])

    # The first admin to open this page is the owner of the lent keys, until someone says otherwise.
    config = Keys.config()
    if config.owner_uuid == nil and me, do: Keys.save_config!(me, config.shared)

    {:ok, socket |> assign(page_title: "API access", me: me) |> load()}
  end

  defp load(socket) do
    config = Keys.config()
    grants = Keys.all_grants()
    stats = Keys.stats(30) |> Map.new(&{&1.uuid, &1})
    users = Auth.list_users_paginated(page: 1, page_size: 500).users

    rows =
      users
      |> Enum.map(fn u ->
        %{
          user: u,
          grant: grants[u.uuid],
          owner?: u.uuid == config.owner_uuid,
          stat: stats[u.uuid],
          today_plays: if(grants[u.uuid], do: Keys.plays_today(u.uuid), else: 0)
        }
      end)
      |> Enum.sort_by(
        &{if(&1.grant, do: 0, else: 1), -((&1.stat && &1.stat.score) || 0), &1.user.email}
      )

    owner_has =
      if config.owner_uuid do
        Roki.Laev.dir(config.owner_uuid) |> Laev.Config.read_dir()
      else
        %{}
      end

    assign(socket,
      config: config,
      grants: grants,
      rows: rows,
      owner_has: owner_has,
      owner: Enum.find(users, &(&1.uuid == config.owner_uuid)),
      summary: summary(rows)
    )
  end

  defp summary(rows) do
    granted = Enum.filter(rows, & &1.grant)
    used = fn r, f -> (r.stat && Map.get(r.stat, f)) || 0 end

    %{
      granted: length(granted),
      today: granted |> Enum.map(&used.(&1, :today)) |> Enum.sum(),
      active: Enum.count(granted, &(used.(&1, :week) > 0)),
      idle: Enum.count(granted, &(used.(&1, :week) == 0))
    }
  end

  @impl true
  def handle_event("grant", %{"uuid" => uuid}, socket) do
    Keys.grant!(uuid)

    # Their account is ready before they open it: no key page to fill in.
    unless Roki.Laev.connected?(uuid), do: Task.start(fn -> Roki.Laev.setup_granted(uuid) end)

    {:noreply, load(socket)}
  end

  def handle_event("toggle_key", %{"uuid" => uuid, "perm" => perm}, socket) do
    g = socket.assigns.grants[uuid] || %{keys: [], heavy: false}
    keys = if perm in g.keys, do: List.delete(g.keys, perm), else: g.keys ++ [perm]
    Keys.set_access!(uuid, %{keys: keys, heavy: g.heavy})
    unless Roki.Laev.connected?(uuid), do: Task.start(fn -> Roki.Laev.setup_granted(uuid) end)
    {:noreply, load(socket)}
  end

  def handle_event("toggle_heavy", %{"uuid" => uuid}, socket) do
    g = socket.assigns.grants[uuid] || %{keys: [], heavy: false}
    Keys.set_access!(uuid, %{keys: g.keys, heavy: not g.heavy})
    {:noreply, load(socket)}
  end

  def handle_event("revoke", %{"uuid" => uuid}, socket) do
    Keys.revoke!(uuid)
    {:noreply, load(socket)}
  end

  def handle_event("cap", %{"uuid" => uuid, "plays" => plays}, socket) do
    value =
      case Integer.parse(String.trim(plays)) do
        {n, ""} when n >= 0 -> n
        _ -> nil
      end

    Keys.set_daily_plays!(uuid, value)
    {:noreply, load(socket)}
  end

  def handle_event("share", params, socket) do
    on = for {id, _, _} <- Keys.permissions(), params[id] == "true", do: id
    shared = Keys.names_for(on)
    Keys.save_config!(socket.assigns.config.owner_uuid, shared)
    {:noreply, load(socket)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, labels: @labels, kind_labels: @kind_labels)

    ~H"""
    <div class="mx-auto max-w-6xl space-y-8 p-4 sm:p-6">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 class="text-2xl font-bold">API access</h1>
          <p class="text-sm text-base-content/60">
            Accounts you let use your API keys. They never see the keys and need none of their own; you can take
            the access back at any time.
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-sm btn-ghost gap-1">
          <.icon name="hero-arrow-path" class="h-4 w-4" /> Refresh
        </button>
      </div>

      <div class="stats stats-vertical w-full border border-base-300 sm:stats-horizontal">
        <div class="stat">
          <div class="stat-title">Accounts with access</div>
          <div class="stat-value text-2xl">{@summary.granted}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Uses today</div>
          <div class="stat-value text-2xl">{@summary.today}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Active this week</div>
          <div class="stat-value text-2xl">{@summary.active}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Not used this week</div>
          <div class="stat-value text-2xl">{@summary.idle}</div>
        </div>
      </div>

      <section class="card border border-base-300 bg-base-100 p-4">
        <h2 class="font-semibold">Keys lent</h2>
        <p class="mb-3 text-sm text-base-content/60">
          Taken from
          <strong>{(@owner && (@owner.email || @owner.username)) || "no account yet"}</strong>
          — the account whose Settings holds them. An account that has a key of its own keeps using that one.
        </p>
        <form phx-change="share" class="flex flex-wrap gap-x-6 gap-y-2">
          <label
            :for={{id, label, names} <- Roki.Keys.permissions()}
            class="flex cursor-pointer items-center gap-2 text-sm"
          >
            <input type="hidden" name={id} value="false" />
            <input
              type="checkbox"
              name={id}
              value="true"
              checked={Enum.all?(names, &(&1 in @config.shared))}
              class="checkbox checkbox-sm"
            />
            {label}
            <span
              :if={Enum.any?(names, &(not Map.has_key?(@owner_has, Laev.Config.keys()[&1])))}
              class="text-xs text-warning"
            >
              (not set)
            </span>
          </label>
        </form>
      </section>

      <section class="overflow-x-auto rounded-box border border-base-300">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Account</th>
              <th :for={{_id, label, _} <- Roki.Keys.permissions()} class="text-center">{label}</th>
              <th
                class="text-center"
                title="May have the server re-encode HEVC and similar videos for the browser (heavy on the server). Without it, the browser plays only H.264 releases."
              >
                Heavy encode
              </th>
              <th></th>
              <th title="Plays a day; blank for no cap">Daily plays</th>
              <th class="text-right">Today</th>
              <th class="text-right">7 days</th>
              <th class="text-right">30 days</th>
              <th>30-day detail</th>
              <th>Last used</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @rows} class={!r.grant && "opacity-70"}>
              <td>
                <div class="font-medium">{r.user.email}</div>
                <div class="text-xs text-base-content/50">{r.user.username}</div>
              </td>
              <td :for={{id, label, names} <- Roki.Keys.permissions()} class="text-center">
                <span :if={r.owner?} class="text-base-content/40">—</span>
                <button
                  :if={!r.owner?}
                  phx-click="toggle_key"
                  phx-value-uuid={r.user.uuid}
                  phx-value-perm={id}
                  disabled={not Enum.all?(names, &(&1 in @config.shared))}
                  class={[
                    "btn btn-xs w-14",
                    r.grant && id in r.grant.keys && "btn-success",
                    !(r.grant && id in r.grant.keys) && "btn-outline btn-error"
                  ]}
                  title={"#{label}: " <> if(r.grant && id in r.grant.keys, do: "allowed — click to disable", else: "off — click to allow")}
                >
                  {if r.grant && id in r.grant.keys, do: "on", else: "off"}
                </button>
              </td>
              <td class="text-center">
                <span :if={r.owner?} class="badge badge-ghost">owner</span>
                <button
                  :if={!r.owner?}
                  phx-click="toggle_heavy"
                  phx-value-uuid={r.user.uuid}
                  class={[
                    "btn btn-xs w-14",
                    r.grant && r.grant.heavy && "btn-success",
                    !(r.grant && r.grant.heavy) && "btn-outline btn-error"
                  ]}
                  title={"Heavy re-encoding: " <> if(r.grant && r.grant.heavy, do: "allowed — click to disable", else: "off (browser plays H.264 releases only) — click to allow")}
                >
                  {if r.grant && r.grant.heavy, do: "on", else: "off"}
                </button>
              </td>
              <td class="whitespace-nowrap">
                <button
                  :if={!r.owner? and !r.grant}
                  phx-click="grant"
                  phx-value-uuid={r.user.uuid}
                  class="btn btn-xs btn-ghost"
                >
                  Allow all
                </button>
                <button
                  :if={!r.owner? and r.grant}
                  phx-click="revoke"
                  phx-value-uuid={r.user.uuid}
                  data-confirm={"Take everything away from #{r.user.email}?"}
                  class="btn btn-xs btn-ghost"
                >
                  Remove all
                </button>
              </td>
              <td>
                <form :if={r.grant && r.grant.keys != []} phx-change="cap" phx-debounce="600">
                  <input type="hidden" name="uuid" value={r.user.uuid} />
                  <input
                    type="number"
                    min="0"
                    name="plays"
                    value={r.grant.daily_plays}
                    placeholder="none"
                    class="input input-xs input-bordered w-20"
                  />
                  <span :if={r.grant.daily_plays} class="ml-1 text-xs text-base-content/50">
                    {r.today_plays} used
                  </span>
                </form>
              </td>
              <td class="text-right tabular-nums">{(r.stat && r.stat.today) || 0}</td>
              <td class="text-right tabular-nums">{(r.stat && r.stat.week) || 0}</td>
              <td class="text-right tabular-nums">{(r.stat && r.stat.total) || 0}</td>
              <td class="text-xs text-base-content/70">
                <span
                  :for={{kind, label} <- @kind_labels}
                  :if={r.stat && r.stat.kinds[kind]}
                  class="mr-2 whitespace-nowrap"
                >
                  {r.stat.kinds[kind]} {label}
                </span>
              </td>
              <td class="whitespace-nowrap text-xs">{(r.stat && r.stat.last_day) || "never"}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end
end
