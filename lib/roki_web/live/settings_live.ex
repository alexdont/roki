defmodule RokiWeb.SettingsLive do
  @moduledoc """
  `/:username/settings` — laev's settings for this user, the same ones the terminal
  app's Settings screen has: how playback behaves, languages, the options only the
  terminal uses, the API keys, and the sync connection.

  Laev describes the settings as data (`Laev.Settings`) and checks every change, so
  this page is a form over that: a choice or a text field saves as soon as it
  changes; a key is only saved once the service (Real-Debrid, TorBox, TMDB) confirms
  it works; and a secret is never sent back to the browser — the page sees it masked.

  Changes reach the terminal app on its next sync when the API keys are carried in
  the laev key; without that they stay on this account.
  """
  use RokiWeb, :live_view

  alias Roki.{Laev, RateLimit}

  # Settings that only the terminal app acts on. They are listed so you can see what is
  # set, but cannot be changed from here — change them in the terminal app.
  @cli_only ~w(LAEV_PLAYER LAEV_SKIP LAEV_POSTERS LAEV_DOWNLOAD_DIR LAEV_MPV_ARGS)

  # `web` is this site's own section (`Roki.Laev.web_settings/1`), not one of laev's groups.
  @groups [
    playback: "Playback",
    language: "Language",
    cli: "Terminal app only"
  ]

  # The resolution ceiling is two settings: laev's own (external player and terminal app, any
  # value) and the site's (the browser player, nothing above 1080p), shown one under the other.
  @web_hints %{
    "browser_max_resolution" =>
      "For the browser player, up to 1080p: a browser cannot decode HEVC, so more would mean the server re-encoding the release. Set the 4K you want under the external player."
  }
  @web_labels %{"browser_max_resolution" => "Resolution ceiling — browser player"}
  @labels %{"LAEV_MAX_RESOLUTION" => "Resolution ceiling — external player & terminal app"}

  @hints %{
    "LAEV_PLAYER" =>
      "Which player the terminal app opens. On this site each device chooses on the title page: Browser or VLC.",
    "LAEV_AUTO_SOURCE" => "Play the best source instead of asking which one.",
    "LAEV_MAX_RESOLUTION" =>
      "The highest resolution to start on its own in VLC or another external player and in the terminal app. Any value. Every release is still listed.",
    "LAEV_STRICT_RESOLUTION" =>
      "Drop releases above the ceiling of the player you are using before they are even checked.",
    "LAEV_AUTOPLAY" => "Start the next episode when one ends.",
    "LAEV_SKIP" =>
      "Intros and credits: ask with a button, skip automatically, or leave alone. Not available on this site yet.",
    "LAEV_LANG" =>
      "Preferred audio language, like en. Releases in other languages sink in the ranking.",
    "LAEV_SUBS" => "Preferred subtitle language, like en. Blank follows the audio language.",
    "LAEV_POSTERS" => "How the terminal app draws poster previews.",
    "LAEV_DOWNLOAD_DIR" => "Where the terminal app saves downloads.",
    "LAEV_MPV_ARGS" => "Extra arguments the terminal app passes to mpv."
  }

  # Only these three can be asked whether they work; the rest are saved as pasted.
  @checkable ~w(RD_TOKEN TORBOX_API_KEY TMDB_API_KEY)

  @placeholders %{"LAEV_LANG" => "en", "LAEV_SUBS" => "same as audio"}

  @key_help %{
    "RD_TOKEN" => "https://real-debrid.com/apitoken",
    "TORBOX_API_KEY" => "https://torbox.app/settings",
    "TMDB_API_KEY" => "https://www.themoviedb.org/settings/api",
    "OPENSUBTITLES_API_KEY" => "https://www.opensubtitles.com/consumers",
    "JIMAKU_API_KEY" => "https://jimaku.cc/account",
    "MAL_CLIENT_ID" => "https://myanimelist.net/apiconfig"
  }

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    case RokiWeb.UserGuard.check(socket, username) do
      {:redirect, to} ->
        {:ok, push_navigate(socket, to: to)}

      {:ok, uuid} ->
        linked? = Laev.connected?(uuid)

        socket =
          socket
          |> assign(:page_title, "Settings")
          |> assign(:username, username)
          |> assign(:uuid, uuid)
          |> assign(:state, if(linked?, do: :loading, else: :not_connected))
          |> assign(:settings, [])
          |> assign(:web, %{})
          |> assign(:device_player, device_player(socket))
          |> assign(:saved, nil)
          |> assign(:editing, MapSet.new())
          |> assign(:results, %{})
          |> assign(:sync, nil)
          |> assign(:carrying?, false)
          |> assign(:server, nil)
          |> assign(:busy, nil)
          |> assign(:error, nil)

        {:ok, if(connected?(socket) and linked?, do: load(socket), else: socket)}
    end
  end

  defp device_player(socket) do
    params = if connected?(socket), do: get_connect_params(socket) || %{}, else: %{}
    if params["player"] == "browser", do: "browser", else: "external"
  end

  defp load(socket) do
    uuid = socket.assigns.uuid

    socket
    |> start_async(:settings, fn ->
      {Laev.settings(uuid), Laev.carrying_keys?(uuid), Laev.sync_server(uuid)}
    end)
    |> start_async(:sync_status, fn -> Laev.sync_status(uuid) end)
    |> start_async(:web, fn -> Laev.web_settings(uuid) end)
  end

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  # Which player this device uses: remembered in the browser itself (the hook-less
  # `roki:player` event writes it), read back from the socket params on connect.
  def handle_event("change", %{"_target" => ["d", "player"], "d" => %{"player" => mode}}, socket)
      when mode in ["external", "browser"] do
    Process.send_after(self(), {:clear_saved, "device_player"}, 2_000)

    {:noreply,
     socket
     |> assign(device_player: mode, saved: "device_player")
     |> push_event("roki:player", %{mode: mode})}
  end

  def handle_event("change", %{"_target" => ["w", key], "w" => values}, socket) do
    case Laev.put_web_setting(socket.assigns.uuid, key, values[key] || "") do
      :ok ->
        Process.send_after(self(), {:clear_saved, key}, 2_000)

        {:noreply,
         socket |> assign(saved: key, error: nil) |> update(:web, &Map.put(&1, key, values[key]))}

      {:error, reason} ->
        {:noreply, assign(socket, error: "#{key}: #{reason}")}
    end
  end

  # The terminal app's own settings are not changed from the site (the inputs are disabled;
  # this is for anyone who sends the event anyway).
  def handle_event("change", %{"_target" => ["s", key]}, socket) when key in @cli_only,
    do: {:noreply, assign(socket, error: "#{key} can only be changed in the terminal app.")}

  def handle_event("change", %{"_target" => ["s", key], "s" => values}, socket) do
    case Laev.put_setting(socket.assigns.uuid, key, values[key] || "") do
      :ok ->
        Process.send_after(self(), {:clear_saved, key}, 2_000)
        {:noreply, socket |> assign(saved: key, error: nil) |> refresh_settings()}

      {:error, reason} ->
        {:noreply, assign(socket, error: "#{key}: " <> Laev.explain(reason))}
    end
  end

  def handle_event("change", _params, socket), do: {:noreply, socket}

  def handle_event("edit", %{"key" => key}, socket),
    do: {:noreply, update(socket, :editing, &MapSet.put(&1, key))}

  def handle_event("cancel", %{"key" => key}, socket),
    do:
      {:noreply,
       socket
       |> update(:editing, &MapSet.delete(&1, key))
       |> update(:results, &Map.delete(&1, key))}

  def handle_event("check", %{"key" => key}, socket), do: {:noreply, check(socket, key)}

  def handle_event("replace", %{"key" => key, "value" => value}, socket) do
    uuid = socket.assigns.uuid

    case RateLimit.check(:key_check, {:user, uuid}, 10, 60_000) do
      :ok ->
        {:noreply,
         socket
         |> put_result(key, :checking)
         |> start_async({:replace, key}, fn -> Laev.replace_key(uuid, key, value) end)}

      {:error, {:rate_limited, secs}} ->
        {:noreply, put_result(socket, key, {:error, "slow down — try again in #{secs}s"})}
    end
  end

  def handle_event("remove", %{"key" => key}, socket) do
    :ok = Laev.remove_key(socket.assigns.uuid, key)
    {:noreply, socket |> put_result(key, nil) |> refresh_settings()}
  end

  def handle_event("toggle_keys", _params, socket) do
    uuid = socket.assigns.uuid
    on? = not socket.assigns.carrying?

    {:noreply,
     socket
     |> assign(error: nil, busy: "Updating…")
     |> start_async(:sync_op, fn -> Laev.set_carry_keys(uuid, on?) end)}
  end

  def handle_event("sync", _params, socket) do
    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(error: nil, busy: "Syncing…")
     |> start_async(:sync_op, fn -> Laev.sync(uuid) end)}
  end

  def handle_event("disconnect", _params, socket) do
    :ok = Laev.disconnect(socket.assigns.uuid)
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.username}/home")}
  end

  defp check(socket, key) do
    uuid = socket.assigns.uuid

    case RateLimit.check(:key_check, {:user, uuid}, 10, 60_000) do
      :ok ->
        socket
        |> put_result(key, :checking)
        |> start_async({:check, key}, fn -> Laev.check_key(uuid, key) end)

      {:error, {:rate_limited, secs}} ->
        put_result(socket, key, {:error, "slow down — try again in #{secs}s"})
    end
  end

  defp put_result(socket, key, nil), do: update(socket, :results, &Map.delete(&1, key))
  defp put_result(socket, key, result), do: update(socket, :results, &Map.put(&1, key, result))

  defp refresh_settings(socket), do: assign(socket, :settings, Laev.settings(socket.assigns.uuid))

  @impl true
  def handle_info({:clear_saved, key}, socket) do
    {:noreply, if(socket.assigns.saved == key, do: assign(socket, :saved, nil), else: socket)}
  end

  # ── async results ──────────────────────────────────────────────────

  @impl true
  def handle_async(:settings, {:ok, {settings, carrying?, server}}, socket),
    do:
      {:noreply,
       assign(socket, state: :ready, settings: settings, carrying?: carrying?, server: server)}

  def handle_async(:settings, {:exit, _}, socket),
    do: {:noreply, assign(socket, error: "Could not read your settings.")}

  def handle_async(:web, {:ok, web}, socket), do: {:noreply, assign(socket, :web, web)}
  def handle_async(:web, {:exit, _}, socket), do: {:noreply, socket}

  def handle_async(:sync_status, {:ok, status}, socket),
    do: {:noreply, assign(socket, :sync, status)}

  def handle_async(:sync_status, {:exit, _}, socket),
    do: {:noreply, assign(socket, :sync, {:error, :unreachable})}

  def handle_async({:check, key}, {:ok, result}, socket),
    do: {:noreply, put_result(socket, key, normalize(result))}

  def handle_async({:check, key}, {:exit, _}, socket),
    do: {:noreply, put_result(socket, key, {:error, "check failed"})}

  def handle_async({:replace, key}, {:ok, {:ok, detail}}, socket) do
    {:noreply,
     socket
     |> update(:editing, &MapSet.delete(&1, key))
     |> put_result(key, {:ok, detail})
     |> refresh_settings()}
  end

  def handle_async({:replace, key}, {:ok, {:error, reason}}, socket),
    do: {:noreply, put_result(socket, key, {:error, Laev.explain(reason)})}

  def handle_async({:replace, key}, {:exit, _}, socket),
    do: {:noreply, put_result(socket, key, {:error, "could not save"})}

  def handle_async(:sync_op, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: nil, error: "Sync failed: " <> Laev.explain(reason))}

  def handle_async(:sync_op, {:ok, _}, socket) do
    {:noreply, socket |> assign(busy: nil) |> load()}
  end

  def handle_async(:sync_op, {:exit, _}, socket),
    do: {:noreply, assign(socket, busy: nil, error: "Sync failed.")}

  defp normalize({:ok, detail}), do: {:ok, detail}
  defp normalize({:error, reason}), do: {:error, Laev.explain(reason)}

  # ── view ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    by_group =
      Enum.group_by(assigns.settings, &if(&1.key in @cli_only, do: :cli, else: &1.group))

    assigns =
      assign(assigns,
        groups: @groups,
        by_group: by_group,
        keys: Map.get(by_group, :keys, []),
        key_help: @key_help,
        checkable: @checkable,
        web_specs: Laev.web_setting_specs(),
        web_hints: @web_hints,
        web_labels: @web_labels,
        labels: @labels
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@username}/settings"}
    >
      <div class="mx-auto max-w-3xl space-y-10">
        <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Settings</h1>

        <div :if={@state == :not_connected} class="alert">
          <span>Connect laev on your shelf to manage its settings.</span>
          <.link navigate={~p"/#{@username}/home"} class="btn btn-sm">Go to your shelf</.link>
        </div>

        <p :if={@error} class="alert alert-error text-sm">{@error}</p>

        <div :if={@state == :loading} class="flex justify-center gap-3 py-16 text-base-content/60">
          <span class="loading loading-spinner"></span> Loading your settings…
        </div>

        <form
          :if={@state == :ready}
          id="settings-form"
          phx-change="change"
          class="space-y-10"
          onsubmit="return false"
        >
          <section
            :for={{group, title} <- @groups}
            :if={@by_group[group]}
            class="space-y-1"
          >
            <h2 class="text-xl font-semibold">{title}</h2>
            <p :if={group == :cli} class="pb-1 text-sm text-base-content/60">
              These only do something in the laev terminal app, so they can't be changed here.
              Change them there; they show up here when your devices sync.
            </p>
            <div class="divide-y divide-base-300">
              <.device_row :if={group == :playback} value={@device_player} saved={@saved} />
              <%= for s <- @by_group[group] || [] do %>
                <.setting_row s={s} saved={@saved} locked={group == :cli} label={@labels[s.key]} />
                <.web_row
                  :for={{key, spec} <- web_rows_after(s.key, @web_specs)}
                  key={key}
                  spec={spec}
                  value={@web[key] || spec.default}
                  label={@web_labels[key]}
                  hint={@web_hints[key]}
                  saved={@saved}
                />
              <% end %>
            </div>
          </section>
        </form>

        <section :if={@state == :ready} class="space-y-1">
          <h2 class="text-xl font-semibold">Connections</h2>
          <p class="pb-2 text-sm text-base-content/60">
            Your API keys. A key is only saved once the service confirms it works, and it is never shown
            in full again.
          </p>
          <div class="divide-y divide-base-300">
            <.key_row
              :for={k <- @keys}
              k={k}
              editing={MapSet.member?(@editing, k.key)}
              result={@results[k.key]}
              help={@key_help[k.key]}
              checkable={k.key in @checkable}
            />
          </div>
        </section>

        <section :if={@state == :ready} class="space-y-3">
          <h2 class="text-xl font-semibold">Sync</h2>
          <div class="space-y-1 text-sm">
            <p>
              Syncing with <code>{@server}</code>
            </p>
            <p :if={match?({:ok, _}, @sync)} class="text-base-content/70">
              {sync_summary(@sync)}
            </p>
            <p :if={match?({:error, _}, @sync)} class="text-error">
              The sync server isn't answering right now.
            </p>
            <p :if={@sync == nil} class="text-base-content/50">Checking…</p>
          </div>

          <label class="flex cursor-pointer items-start gap-3">
            <input
              type="checkbox"
              class="checkbox mt-0.5"
              checked={@carrying?}
              phx-click="toggle_keys"
              disabled={@busy != nil}
            />
            <span class="text-sm">
              <span class="font-medium">Carry my API keys in the laev key</span>
              <span class="block text-base-content/60">
                Keys and these settings are encrypted with the half of your laev key that never leaves
                your devices, so your terminal app and this account share them. Off: only your history
                syncs, and settings stay on this account.
              </span>
            </span>
          </label>

          <div class="flex flex-wrap items-center gap-2">
            <button phx-click="sync" class="btn btn-sm" disabled={@busy != nil}>
              <.icon
                name="hero-arrow-path"
                class={if @busy, do: "h-4 w-4 animate-spin", else: "h-4 w-4"}
              />
              {@busy || "Sync now"}
            </button>
            <button
              phx-click="disconnect"
              data-confirm="Disconnect laev and delete everything pulled for this account? Your laev key's server keeps its copy."
              class="btn btn-sm btn-ghost text-error"
            >
              Disconnect laev
            </button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :value, :string, required: true
  attr :saved, :any, default: nil

  defp device_row(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 py-3 sm:flex-row sm:items-center sm:gap-6">
      <label for="d-player" class="min-w-0 sm:w-1/2">
        <span class="font-medium">Player on this device</span>
        <span class="block text-xs text-base-content/60">
          What Play does on the title page. The external player (VLC) is the default: the full
          release, any resolution, nothing converted on the server. "Browser" plays in the
          browser, up to 1080p. Remembered in this browser, so each of your devices has its own.
        </span>
      </label>
      <div class="flex items-center gap-2 sm:w-1/2">
        <select id="d-player" name="d[player]" class="select select-bordered w-full">
          <option value="external" selected={@value == "external"}>
            VLC / external player (default)
          </option>
          <option value="browser" selected={@value == "browser"}>Browser</option>
        </select>
        <span :if={@saved == "device_player"} class="shrink-0 text-sm text-success">Saved</span>
      </div>
    </div>
    """
  end

  attr :key, :string, required: true
  attr :spec, :map, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :saved, :any, default: nil

  defp web_row(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 py-3 sm:flex-row sm:items-center sm:gap-6">
      <label for={"w-" <> @key} class="min-w-0 sm:w-1/2">
        <span class="font-medium">{@label}</span>
        <span :if={@hint} class="block text-xs text-base-content/60">{@hint}</span>
      </label>
      <div class="flex items-center gap-2 sm:w-1/2">
        <select id={"w-" <> @key} name={"w[#{@key}]"} class="select select-bordered w-full">
          <option :for={o <- @spec.allowed} value={o} selected={@value == o}>
            {o}{if o == @spec.default, do: " (default)"}
          </option>
        </select>
        <span :if={@saved == @key} class="shrink-0 text-sm text-success">Saved</span>
      </div>
    </div>
    """
  end

  # The site's browser cap sits right under laev's ceiling.
  defp web_rows_after("LAEV_MAX_RESOLUTION", specs),
    do: Enum.filter(specs, &(elem(&1, 0) == "browser_max_resolution"))

  defp web_rows_after(_key, _specs), do: []

  attr :s, :map, required: true
  attr :saved, :any, default: nil
  attr :locked, :boolean, default: false
  attr :label, :string, default: nil

  defp setting_row(assigns) do
    assigns =
      assign(assigns,
        hint: @hints[assigns.s.key],
        placeholder: @placeholders[assigns.s.key] || "",
        id: "s-" <> assigns.s.key
      )

    ~H"""
    <div
      class={[
        "flex flex-col gap-1.5 py-3 sm:flex-row sm:items-center sm:gap-6",
        @locked && "opacity-60"
      ]}
      title={if @locked, do: "Terminal app only: change it in the laev CLI"}
    >
      <label for={@id} class="min-w-0 sm:w-1/2">
        <span class="font-medium">{@label || @s.label}</span>
        <span :if={@locked} class="badge badge-sm badge-ghost ml-2 align-middle">CLI only</span>
        <span :if={@hint} class="block text-xs text-base-content/60">{@hint}</span>
      </label>
      <div class="flex items-center gap-2 sm:w-1/2">
        <select
          :if={match?({:one_of, _}, @s.type)}
          disabled={@locked}
          id={@id}
          name={"s[#{@s.key}]"}
          class="select select-bordered w-full"
        >
          <option :if={!@s.set?} value="" disabled selected>default</option>
          <option :for={o <- options(@s)} value={o} selected={@s.value == o}>{o}</option>
        </select>
        <input
          :if={@s.type == :text}
          id={@id}
          name={"s[#{@s.key}]"}
          type="text"
          disabled={@locked}
          value={@s.value}
          placeholder={@placeholder}
          phx-debounce="blur"
          autocomplete="off"
          spellcheck="false"
          class="input input-bordered w-full"
        />
        <span :if={@saved == @s.key} class="shrink-0 text-sm text-success">Saved</span>
      </div>
    </div>
    """
  end

  # What this server can offer, plus whatever the account already has — a terminal
  # player (mpv) chosen on a laptop is still a valid value even though this server
  # has no mpv to offer.
  defp options(%{key: "LAEV_PLAYER", value: value}) do
    all = ~w(vlc mpv browser)
    if value in [nil, ""] or value in all, do: all, else: all ++ [value]
  end

  defp options(%{type: {:one_of, allowed}, value: value}) do
    if value in [nil, ""] or value in allowed, do: allowed, else: allowed ++ [value]
  end

  attr :k, :map, required: true
  attr :editing, :boolean, default: false
  attr :result, :any, default: nil
  attr :help, :string, default: nil
  attr :checkable, :boolean, default: false

  defp key_row(assigns) do
    ~H"""
    <div class="space-y-2 py-3">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <div class="min-w-0 flex-1">
          <div class="font-medium">{@k.label}</div>
          <div class={["font-mono text-sm", !@k.set? && "text-base-content/40"]}>
            {if @k.set?, do: @k.value, else: "not set"}
          </div>
        </div>
        <div :if={!@editing} class="flex shrink-0 items-center gap-1">
          <button
            :if={@k.set? and @checkable}
            phx-click="check"
            phx-value-key={@k.key}
            class="btn btn-xs"
            disabled={@result == :checking}
          >
            Check
          </button>
          <button phx-click="edit" phx-value-key={@k.key} class="btn btn-xs">
            {if @k.set?, do: "Replace", else: "Add"}
          </button>
          <button
            :if={@k.set?}
            phx-click="remove"
            phx-value-key={@k.key}
            data-confirm={"Remove the #{@k.label}?"}
            class="btn btn-xs btn-ghost text-error"
          >
            Remove
          </button>
        </div>
      </div>

      <form
        :if={@editing}
        id={"replace-" <> @k.key}
        phx-submit="replace"
        class="flex flex-wrap items-center gap-2"
      >
        <input type="hidden" name="key" value={@k.key} />
        <input
          type="password"
          name="value"
          placeholder="paste the key"
          autocomplete="off"
          spellcheck="false"
          class="input input-bordered input-sm min-w-0 flex-1 font-mono"
        />
        <button type="submit" class="btn btn-sm btn-primary" disabled={@result == :checking}>
          <span :if={@result == :checking} class="loading loading-spinner loading-xs"></span> Save
        </button>
        <button type="button" phx-click="cancel" phx-value-key={@k.key} class="btn btn-sm btn-ghost">
          Cancel
        </button>
        <a
          :if={@help}
          href={@help}
          target="_blank"
          rel="noopener"
          class="text-xs text-base-content/60 underline"
        >
          where to find it
        </a>
      </form>

      <p
        :if={@result == :checking and !@editing}
        class="flex items-center gap-2 text-sm text-base-content/60"
      >
        <span class="loading loading-spinner loading-xs"></span> Asking the service…
      </p>
      <p :if={match?({:ok, _}, @result)} class="text-sm text-success">✓ {elem(@result, 1)}</p>
      <p :if={match?({:error, _}, @result)} class="text-sm text-error">✗ {elem(@result, 1)}</p>
    </div>
    """
  end

  defp sync_summary({:ok, counts}) do
    parts =
      [
        {:watchlist, "saved"},
        {:resume, "in history"},
        {:positions, "positions"},
        {:anime, "anime"}
      ]
      |> Enum.flat_map(fn {k, label} ->
        if (counts[k] || 0) > 0, do: ["#{counts[k]} #{label}"], else: []
      end)

    if parts == [],
      do: "Connected. Nothing synced yet.",
      else: "Connected · " <> Enum.join(parts, " · ")
  end
end
