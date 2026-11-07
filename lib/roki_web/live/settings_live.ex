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
  # value) and the site's (the browser player; 4K only where the browser decodes the video
  # itself, 1080p elsewhere), shown one under the other.
  @web_hints %{
    "play_from" =>
      "Where the sources page searches first, and where Play finds its source by itself. The original collection is the releases your debrid account streams; PenguPlay is plain https streams that need no account; Nuvio runs the providers you choose below. The sources page has a switch to look at any of the three either way.",
    "sources_cache" =>
      "Releases already found and checked are kept this long, so Play starts at once instead of searching again. Retry on a title looks for new ones.",
    "player_look" =>
      "How the browser player's controls look. Sleek: rounded buttons, frosted menus, outlined study tools. Classic: the original block buttons. Every control and shortcut is the same in both.",
    "anime_audio" =>
      "For anime. Your language plays the dub when a release has one. Japanese plays the original and looks for subtitles in your language — releases are searched, ranked and started with that in mind. A study session's languages win over this.",
    "browser_work" =>
      "For the browser player. On this device, the release is read straight from its host and taken apart, decoded and played right here — 4K HEVC, Dolby and DTS sound included — and the server does nothing (for Real-Debrid it passes the bytes along, nothing more). On the server, the release is converted there first, as before. If a release will not play on the device, the server takes over for it by itself.",
    "external_app" =>
      "What Play opens when this device uses an external player. It starts by itself; if your device asks, allow it. The download option gives you an .m3u file to open yourself.",
    "browser_max_resolution" =>
      "For the browser player. 4K plays where the browser decodes the release's video itself (HEVC on Apple devices and most recent PCs); any other browser stays at 1080p, since more would mean the server re-encoding the release.",
    "browser_max_size" =>
      "For the browser player: a release larger than this is left out of the list. Each play is downloaded whole into the server's cache for a few hours, so a 90 GB remux picked by accident costs real disk. The external player has no such limit."
  }
  @web_labels %{
    "play_from" => "Play from",
    "browser_max_resolution" => "Resolution ceiling — browser player",
    "browser_max_size" => "Size limit — browser player",
    "anime_audio" => "Anime audio",
    "browser_work" => "Browser player works on",
    "external_app" => "External player app",
    "sources_cache" => "Keep found sources",
    "player_look" => "Player look"
  }
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
      "Releases with this audio rank first; ones in another language sink. English by default.",
    "LAEV_SUBS" =>
      "The subtitle language looked for and shown first. English by default; Off turns subtitles off.",
    "LAEV_POSTERS" => "How the terminal app draws poster previews.",
    "LAEV_DOWNLOAD_DIR" => "Where the terminal app saves downloads.",
    "LAEV_MPV_ARGS" => "Extra arguments the terminal app passes to mpv."
  }

  # Only these three can be asked whether they work; the rest are saved as pasted.
  @checkable ~w(RD_TOKEN TORBOX_API_KEY TMDB_API_KEY)

  @placeholders %{}

  # Settings that are one of the known languages, picked from a list rather than typed.
  @language_keys ~w(LAEV_LANG LAEV_SUBS)

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
          |> assign(:auto_sync, nil)
          |> assign(:sync_timer, nil)
          |> assign(:device_player, device_player(socket))
          |> assign(:saved, nil)
          |> assign(:editing, MapSet.new())
          |> assign(:results, %{})
          |> assign(:sync, nil)
          |> assign(:mal, %{status: :loading, url: nil, error: nil, busy: false})
          |> assign(:tmdb, %{status: :loading, note: nil})
          |> allow_upload(:imdb_csv, accept: ~w(.csv), max_entries: 1, max_file_size: 5_000_000)
          |> assign(:notify, Roki.Notify.choices(uuid))
          |> assign(:carrying?, false)
          |> assign(:server, nil)
          |> assign(:busy, nil)
          |> assign(:error, nil)
          |> assign(:laev_key, nil)
          |> assign(:os, %{key?: false, user: nil, login?: false})
          |> assign(:os_msg, nil)
          |> assign(:pengu, Roki.Pengu.status(uuid))
          |> assign(:pengu_msg, nil)
          |> assign(:nuvio, %{catalog: [], loading: true, schemas: %{}})
          |> assign(:nuvio_msg, nil)
          |> assign(:debrid?, Roki.Laev.debrid?(uuid))
          |> assign(:debrid_msg, nil)
          |> assign(:debrid_busy, false)
          |> assign_reading()

        # The manifest is fetched only when this account has a provider on (the defaults
        # are, until switched off), or when the section's "Load providers" button is
        # pressed. It is cached for an hour.
        socket =
          if connected?(socket) and Roki.Nuvio.Settings.enabled_ids(uuid) != [] do
            start_async(socket, :nuvio, fn -> Roki.Nuvio.catalog(uuid) end)
          else
            update(socket, :nuvio, &%{&1 | loading: false})
          end

        {:ok, if(connected?(socket) and linked?, do: load(socket), else: socket)}
    end
  end

  # The reader's own preferences are kept in the user's `custom_fields` (the reader
  # reads them from there), not in laev's settings, so this part of the page works
  # whether or not the terminal app is connected.
  defp assign_reading(socket) do
    user = PhoenixKit.Users.Auth.Scope.user(socket.assigns.phoenix_kit_current_scope)

    socket
    |> assign(:reader, user)
    |> assign(:page_padding, Roki.Manga.Library.page_padding_defaults(user.custom_fields))
    |> assign(:reader_mal, Roki.Manga.Library.get_tracker_token(user.uuid, "mal"))
    |> assign(:reader_mal_available, Roki.Manga.Trackers.MAL.oauth_ready?())
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
    |> start_async(:mal, fn -> Laev.mal_status(uuid) end)
    |> start_async(:tmdb, fn -> Laev.tmdb_status(uuid) end)
    |> start_async(:os, fn -> Laev.os_login(uuid) end)
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

        {:noreply,
         socket |> assign(saved: key, error: nil) |> refresh_settings() |> schedule_sync()}

      {:error, reason} ->
        {:noreply, assign(socket, error: "#{key}: " <> Laev.explain(reason))}
    end
  end

  def handle_event("change", _params, socket), do: {:noreply, socket}

  # PenguPlay: the install link pasted from pengu.uk, checked against its manifest before it is kept.
  def handle_event("pengu_save", %{"pengu" => %{"url" => url}}, socket) do
    case Roki.Pengu.save_url(socket.assigns.reader, url) do
      {:ok, user} ->
        {:noreply,
         assign(socket,
           reader: user,
           pengu: Roki.Pengu.status(user.uuid),
           pengu_msg: {:ok, "Saved — PenguPlay now searches with your own link."}
         )}

      {:error, text} ->
        {:noreply, assign(socket, :pengu_msg, {:error, text})}
    end
  end

  # Real-Debrid / TorBox for an account that has nothing yet: connected first if need be, each key
  # kept only once its service accepts it.
  def handle_event("debrid_save", %{"debrid" => keys}, %{assigns: %{uuid: uuid}} = socket) do
    keys = Map.take(keys, ~w(RD_TOKEN TORBOX_API_KEY))

    {:noreply,
     socket
     |> assign(debrid_busy: true, debrid_msg: nil)
     |> start_async(:debrid_save, fn -> Roki.Laev.save_debrid(uuid, keys) end)}
  end

  def handle_event("nuvio_toggle", %{"provider" => provider_id}, socket) do
    entry = Enum.find(socket.assigns.nuvio.catalog, &(&1.provider.id == provider_id))
    enabled? = not (entry && entry.enabled)
    user = PhoenixKit.Users.Auth.get_user(socket.assigns.uuid)

    case entry && Roki.Nuvio.Settings.set_enabled(user, provider_id, enabled?) do
      {:ok, _user} ->
        catalog =
          Roki.Nuvio.mark(
            socket.assigns.nuvio.catalog,
            Roki.Nuvio.Settings.enabled_ids(socket.assigns.uuid)
          )

        {:noreply,
         socket
         |> update(:nuvio, &%{&1 | catalog: catalog})
         |> assign(:nuvio_msg, nil)}

      _ ->
        {:noreply, assign(socket, :nuvio_msg, {:error, "Could not save that provider."})}
    end
  end

  def handle_event("nuvio_options", %{"provider" => provider_id}, socket) do
    key = {:nuvio_schema, provider_id}

    {:noreply,
     socket
     |> assign(:nuvio_msg, nil)
     |> start_async(key, fn -> Roki.Nuvio.Settings.schema(provider_id) end)}
  end

  def handle_event("nuvio_save_options", %{"provider" => provider_id} = params, socket) do
    user = PhoenixKit.Users.Auth.get_user(socket.assigns.uuid)
    options = params["options"] || %{}

    case Roki.Nuvio.Settings.set_options(user, provider_id, options) do
      {:ok, _user} ->
        {:noreply, assign(socket, :nuvio_msg, {:ok, "Options saved for #{provider_id}."})}

      _ ->
        {:noreply, assign(socket, :nuvio_msg, {:error, "Could not save those options."})}
    end
  end

  def handle_event("nuvio_load", _params, socket) do
    uuid = socket.assigns.uuid

    {:noreply,
     start_async(
       assign(socket, :nuvio, %{catalog: [], loading: true, schemas: %{}}),
       :nuvio,
       fn -> Roki.Nuvio.catalog(uuid) end
     )}
  end

  def handle_event("nuvio_reset", _params, socket) do
    user = PhoenixKit.Users.Auth.get_user(socket.assigns.uuid)

    case Roki.Nuvio.Settings.reset_providers(user) do
      {:ok, _user} ->
        catalog =
          Roki.Nuvio.mark(
            socket.assigns.nuvio.catalog,
            Roki.Nuvio.Settings.enabled_ids(socket.assigns.uuid)
          )

        {:noreply,
         socket
         |> update(:nuvio, &%{&1 | catalog: catalog})
         |> assign(:nuvio_msg, {:ok, "Back to the default providers."})}

      _ ->
        {:noreply, assign(socket, :nuvio_msg, {:error, "Could not reset the providers."})}
    end
  end

  def handle_event("nuvio_refresh", _params, socket) do
    Roki.Nuvio.Registry.forget()
    uuid = socket.assigns.uuid

    {:noreply,
     start_async(
       assign(socket, :nuvio, %{catalog: [], loading: true, schemas: %{}}),
       :nuvio,
       fn ->
         Roki.Nuvio.catalog(uuid)
       end
     )}
  end

  def handle_event("pengu_remove", _params, socket) do
    case Roki.Pengu.remove_url(socket.assigns.reader) do
      {:ok, user} ->
        {:noreply,
         assign(socket,
           reader: user,
           pengu: Roki.Pengu.status(user.uuid),
           pengu_msg: {:ok, "Your link is removed."}
         )}

      _ ->
        {:noreply, assign(socket, :pengu_msg, {:error, "Could not remove it."})}
    end
  end

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

  def handle_event("save_os", %{"os" => %{"user" => user, "pass" => pass}}, socket) do
    uuid = socket.assigns.uuid

    case RateLimit.check(:key_check, {:user, uuid}, 10, 60_000) do
      :ok ->
        {:noreply,
         socket
         |> assign(:os_msg, :checking)
         |> start_async(:os_save, fn -> Laev.put_os_login(uuid, user, pass) end)}

      {:error, {:rate_limited, secs}} ->
        {:noreply, assign(socket, :os_msg, {:error, "slow down — try again in #{secs}s"})}
    end
  end

  def handle_event("remove", %{"key" => key}, socket) do
    :ok = Laev.remove_key(socket.assigns.uuid, key)
    {:noreply, socket |> put_result(key, nil) |> refresh_settings() |> schedule_sync()}
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

  # MyAnimeList: begin (an address to approve at), finish (the address pasted back), forget.
  def handle_event("mal_start", _params, socket) do
    uuid = socket.assigns.uuid

    case RateLimit.check(:mal_connect, {:user, uuid}, 10, 60_000) do
      :ok ->
        case Laev.mal_begin(uuid) do
          {:ok, url} -> {:noreply, update(socket, :mal, &%{&1 | url: url, error: nil})}
          {:error, why} -> {:noreply, update(socket, :mal, &%{&1 | error: why})}
        end

      {:error, {:rate_limited, secs}} ->
        {:noreply, update(socket, :mal, &%{&1 | error: "Slow down, try again in #{secs}s."})}
    end
  end

  def handle_event("mal_finish", %{"pasted" => pasted}, socket) do
    uuid = socket.assigns.uuid

    case RateLimit.check(:mal_connect, {:user, uuid}, 10, 60_000) do
      :ok ->
        {:noreply,
         socket
         |> update(:mal, &%{&1 | error: nil, busy: true})
         |> start_async(:mal_finish, fn -> Laev.mal_finish(uuid, pasted) end)}

      {:error, {:rate_limited, secs}} ->
        {:noreply, update(socket, :mal, &%{&1 | error: "Slow down, try again in #{secs}s."})}
    end
  end

  # Which kinds of notification to get: each a switch, taking effect at once.
  def handle_event("notify_toggle", %{"key" => key}, socket) do
    wanted = not Map.get(socket.assigns.notify, key, true)

    case Roki.Notify.set(socket.assigns.uuid, key, wanted) do
      :ok -> {:noreply, update(socket, :notify, &Map.put(&1, key, wanted))}
      _ -> {:noreply, socket}
    end
  end

  # TMDB: linking goes through the site's own pages (/tmdb/link and back); unlinking is here.
  def handle_event("tmdb_logout", _params, socket) do
    {:ok, synced?} = Laev.tmdb_logout(socket.assigns.uuid)

    note =
      if synced?,
        do:
          "Unlinked here. Your laev key carries keys between devices, so another device that still has it can bring it back on a sync."

    {:noreply, assign(socket, :tmdb, %{status: %{linked?: false, username: nil}, note: note})}
  end

  def handle_event("imdb_validate", _params, socket), do: {:noreply, socket}

  # An IMDb ratings export, for the dates TMDB does not keep (Roki.ImdbDates).
  def handle_event("imdb_dates", _params, socket) do
    uuid = socket.assigns.uuid

    csv =
      consume_uploaded_entries(socket, :imdb_csv, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case csv do
      [csv] ->
        {:noreply,
         socket
         |> update(:tmdb, &%{&1 | note: "Reading your export…"})
         |> start_async(:imdb_dates, fn -> Roki.ImdbDates.import(uuid, csv) end)}

      _ ->
        {:noreply, update(socket, :tmdb, &%{&1 | note: "Choose the .csv file from IMDb first."})}
    end
  end

  def handle_event("mal_logout", _params, socket) do
    Laev.mal_logout(socket.assigns.uuid)

    {:noreply,
     assign(socket, :mal, %{
       status: %{configured?: true, connected?: false, username: nil},
       url: nil,
       error: nil,
       busy: false
     })}
  end

  def handle_event("show_key", _params, socket) do
    key = if socket.assigns.laev_key, do: nil, else: Laev.sync_key(socket.assigns.uuid)
    {:noreply, assign(socket, :laev_key, key)}
  end

  def handle_event("disconnect", _params, socket) do
    :ok = Laev.disconnect(socket.assigns.uuid)
    {:noreply, push_navigate(socket, to: ~p"/u/#{socket.assigns.username}/corner")}
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

  # A change on this account reaches the terminal app through a sync. So that nobody has to
  # press "Sync now", one runs a few seconds after the last change (several quick changes make
  # one sync). Only when the laev key carries settings; otherwise they stay on this account.
  defp schedule_sync(%{assigns: %{carrying?: true}} = socket) do
    if socket.assigns[:sync_timer], do: Process.cancel_timer(socket.assigns.sync_timer)
    assign(socket, sync_timer: Process.send_after(self(), :auto_sync, 3_000), auto_sync: :waiting)
  end

  defp schedule_sync(socket), do: socket

  @impl true
  def handle_info(:auto_sync, socket) do
    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(sync_timer: nil, auto_sync: :syncing)
     |> start_async(:auto_sync, fn -> Laev.sync(uuid) end)}
  end

  def handle_info({:clear_saved, key}, socket) do
    {:noreply, if(socket.assigns.saved == key, do: assign(socket, :saved, nil), else: socket)}
  end

  # ── async results ──────────────────────────────────────────────────

  @impl true
  # A debrid key was saved: the page is opened again so everything on it is read afresh (laev's
  # settings, the Connections section, the switches).
  def handle_async(:debrid_save, {:ok, :ok}, %{assigns: %{username: username}} = socket),
    do: {:noreply, push_navigate(socket, to: "/u/#{username}/settings")}

  def handle_async(:debrid_save, {:ok, {:error, text}}, socket),
    do: {:noreply, assign(socket, debrid_busy: false, debrid_msg: {:error, text})}

  def handle_async(:debrid_save, _other, socket),
    do:
      {:noreply,
       assign(socket, debrid_busy: false, debrid_msg: {:error, "That did not work. Try again."})}

  def handle_async(:settings, {:ok, {settings, carrying?, server}}, socket),
    do:
      {:noreply,
       assign(socket, state: :ready, settings: settings, carrying?: carrying?, server: server)}

  def handle_async(:settings, {:exit, _}, socket),
    do: {:noreply, assign(socket, error: "Could not read your settings.")}

  def handle_async(:auto_sync, {:ok, {:error, _}}, socket),
    do: {:noreply, assign(socket, auto_sync: :failed)}

  def handle_async(:auto_sync, {:ok, _}, socket),
    do: {:noreply, assign(socket, auto_sync: :done)}

  def handle_async(:auto_sync, {:exit, _}, socket),
    do: {:noreply, assign(socket, auto_sync: :failed)}

  def handle_async(:imdb_dates, {:ok, {:ok, r}}, socket) do
    left =
      if r.kept + r.unlisted + r.unresolved > 0,
        do:
          " #{r.kept} already had a date, #{r.unlisted} are not on your watched list, #{r.unresolved} could not be matched.",
        else: ""

    {:noreply,
     update(socket, :tmdb, &%{&1 | note: "Dated #{r.dated} titles from your export." <> left})}
  end

  def handle_async(:imdb_dates, _other, socket),
    do:
      {:noreply,
       update(
         socket,
         :tmdb,
         &%{
           &1
           | note:
               "That file is not an IMDb ratings export (it needs the Const and Date Rated columns)."
         }
       )}

  def handle_async(:tmdb, {:ok, status}, socket),
    do: {:noreply, update(socket, :tmdb, &%{&1 | status: status})}

  def handle_async(:tmdb, _other, socket),
    do: {:noreply, update(socket, :tmdb, &%{&1 | status: %{linked?: false, username: nil}})}

  def handle_async(:mal, {:ok, status}, socket),
    do: {:noreply, update(socket, :mal, &%{&1 | status: status})}

  def handle_async(:mal, {:exit, _}, socket), do: {:noreply, socket}

  def handle_async(:mal_finish, {:ok, {:ok, name}}, socket) do
    status = %{configured?: true, connected?: true, username: name}
    {:noreply, assign(socket, :mal, %{status: status, url: nil, error: nil, busy: false})}
  end

  def handle_async(:mal_finish, {:ok, {:error, why}}, socket),
    do: {:noreply, update(socket, :mal, &%{&1 | error: why, busy: false})}

  def handle_async(:mal_finish, {:exit, _}, socket),
    do:
      {:noreply,
       update(socket, :mal, &%{&1 | error: "Something went wrong. Try again.", busy: false})}

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

  def handle_async(:os, {:ok, os}, socket), do: {:noreply, assign(socket, :os, os)}
  def handle_async(:os, _other, socket), do: {:noreply, socket}

  def handle_async(:os_save, {:ok, :ok}, socket) do
    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(:os_msg, {:ok, "Saved — OpenSubtitles files can be downloaded now."})
     |> start_async(:os, fn -> Laev.os_login(uuid) end)
     |> schedule_sync()}
  end

  def handle_async(:os_save, {:ok, {:error, why}}, socket),
    do: {:noreply, assign(socket, :os_msg, {:error, why})}

  def handle_async(:os_save, _other, socket),
    do: {:noreply, assign(socket, :os_msg, {:error, "could not save"})}

  def handle_async({:replace, key}, {:ok, {:ok, detail}}, socket) do
    {:noreply,
     socket
     |> update(:editing, &MapSet.delete(&1, key))
     |> put_result(key, {:ok, detail})
     |> refresh_settings()
     |> schedule_sync()}
  end

  def handle_async({:replace, key}, {:ok, {:error, reason}}, socket),
    do: {:noreply, put_result(socket, key, {:error, Laev.explain(reason)})}

  def handle_async({:replace, key}, {:exit, _}, socket),
    do: {:noreply, put_result(socket, key, {:error, "could not save"})}

  def handle_async(:nuvio, {:ok, {:ok, catalog}}, socket),
    do: {:noreply, update(socket, :nuvio, &%{&1 | catalog: catalog, loading: false})}

  def handle_async(:nuvio, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(socket,
         nuvio: %{catalog: [], loading: false, schemas: %{}},
         nuvio_msg: {:error, Roki.Nuvio.message(reason)}
       )}

  def handle_async(:nuvio, _other, socket),
    do: {:noreply, update(socket, :nuvio, &%{&1 | loading: false})}

  def handle_async({:nuvio_schema, provider_id}, {:ok, {:ok, fields}}, socket) do
    {:noreply, update(socket, :nuvio, fn n -> put_in(n.schemas[provider_id], fields) end)}
  end

  def handle_async({:nuvio_schema, _provider_id}, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(
         socket,
         :nuvio_msg,
         {:error, "Options could not be read: #{inspect(reason, limit: 2)}"}
       )}

  def handle_async({:nuvio_schema, _provider_id}, _other, socket),
    do: {:noreply, assign(socket, :nuvio_msg, {:error, "Options could not be read."})}

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

  defp nuvio_on_count(catalog), do: Enum.count(catalog, & &1.enabled)

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
      socket={@socket}
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/u/#{@username}/settings"}
    >
      <div class="mx-auto max-w-3xl space-y-10">
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Settings</h1>
          <a
            href="/phoenix_kit/profile/settings"
            class="text-sm text-base-content/60 hover:text-primary"
          >
            Account: profile picture, name, email, password →
          </a>
        </div>

        <section class="space-y-1">
          <h2 class="text-xl font-semibold">Appearance</h2>
          <div class="flex items-center justify-between gap-4 border-b border-base-300 py-3">
            <div>
              <p class="font-medium">Theme</p>
              <p class="text-sm text-base-content/60">Follow your device, or always light or dark.</p>
            </div>
            <Layouts.theme_toggle />
          </div>
        </section>

        <div :if={@state == :not_connected} class="alert">
          <span>Connect laev in your corner to manage its settings.</span>
          <.link navigate={~p"/u/#{@username}/corner"} class="btn btn-sm">Go to your corner</.link>
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
              <.web_row
                :for={
                  {key, spec} <-
                    if(group == :playback,
                      do: external_app_spec(@web_specs),
                      else: []
                    )
                }
                key={key}
                spec={spec}
                value={@web[key] || spec.default}
                label={@web_labels[key]}
                hint={@web_hints[key]}
                saved={@saved}
              />
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

        <%!-- The manga reader's preferences, absorbed from its own settings page so this
             site has one. Outside the form above: these save themselves with a PUT per
             control (RokiWeb.MangaController), they are not laev settings. --%>
        <section id="reading" class="space-y-1 scroll-mt-4">
          <h2 class="text-xl font-semibold">Reading</h2>
          <p class="pb-2 text-sm text-base-content/60">
            The manga reader: how it opens, how pages turn, and what panel snap does. Every
            change here saves itself and applies to new manga; each manga can still be set
            on its own in the reader.
          </p>
          <RokiWeb.MangaSettings.preferences
            user={@reader}
            page_padding={@page_padding}
            mal_token={@reader_mal}
            mal_available={@reader_mal_available}
          />
        </section>

        <%!-- PenguPlay: a link of your own, or the owner's lent to you. Outside laev's own sections,
             so it works without a laev account (watch history still needs one). --%>
        <section id="penguplay" class="space-y-2 scroll-mt-4">
          <h2 class="text-xl font-semibold">PenguPlay</h2>
          <p class="text-sm text-base-content/60">
            Plain https streams from PenguPlay's providers — no debrid account needed. Sign in at
            <a href="https://pengu.uk" target="_blank" rel="noopener" class="link">pengu.uk</a>
            (Google takes a few seconds), pick your providers, and paste the install link (the one
            ending in <code>/manifest.json</code>) here. Searches then go out under your own account.
          </p>
          <p class="text-sm">
            <span :if={@pengu.kind == :own} class="badge badge-success badge-outline">Your own link</span>
            <span :if={@pengu.kind == :lent} class="badge badge-info badge-outline">Shared link</span>
            <span :if={@pengu.kind == nil} class="badge badge-ghost">Not set up</span>
            <span :if={@pengu.kind == :lent} class="ml-2 text-base-content/70">
              {@pengu.used} of {@pengu.cap} searches used today. A link of your own has no limit.
            </span>
          </p>
          <form phx-submit="pengu_save" class="flex flex-wrap items-center gap-2">
            <input
              type="text"
              name="pengu[url]"
              autocomplete="off"
              spellcheck="false"
              placeholder="https://pengu.uk/…/manifest.json"
              class="input input-bordered input-sm w-full max-w-xl"
            />
            <button class="btn btn-sm btn-primary">
              {if @pengu.kind == :own, do: "Replace link", else: "Save link"}
            </button>
            <button
              :if={@pengu.kind == :own}
              type="button"
              phx-click="pengu_remove"
              data-confirm="Remove your PenguPlay link?"
              class="btn btn-sm btn-ghost text-error"
            >
              Remove
            </button>
          </form>
          <p :if={match?({:ok, _}, @pengu_msg)} class="text-sm text-success">{elem(@pengu_msg, 1)}</p>
          <p :if={match?({:error, _}, @pengu_msg)} class="text-sm text-error">
            {elem(@pengu_msg, 1)}
          </p>
        </section>

        <%!-- Nuvio: providers from the All-in-One-Nuvio manifest, each one enabled by hand and
             run in the sandbox. Independent of PenguPlay and of the debrid collection. --%>
        <section id="nuvio" class="space-y-3 scroll-mt-4">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="text-xl font-semibold">Nuvio</h2>
            <div class="flex flex-wrap gap-2">
              <button
                :if={@nuvio.catalog != []}
                type="button"
                phx-click="nuvio_reset"
                data-confirm="Switch Nuvio back to the default providers? Your choices here are undone; each provider's options are kept."
                disabled={Enum.all?(@nuvio.catalog, &(&1.enabled == &1.default))}
                class="btn btn-xs rounded-full"
              >
                Reset to defaults
              </button>
              <button type="button" phx-click="nuvio_refresh" class="btn btn-xs rounded-full">
                Refresh manifest
              </button>
            </div>
          </div>
          <p class="text-sm text-base-content/60">
            A third collection, discovered from the
            <a
              href="https://github.com/NuvioPlugin/All-in-One-Nuvio"
              target="_blank"
              rel="noopener"
              class="link"
            >All-in-One-Nuvio</a>
            manifest. Providers run one at a time in an isolated Node process; they are not
            trusted, and one that fails does not stop the others.
          </p>
          <p class="rounded-xl border border-warning/40 bg-warning/10 p-3 text-sm">
            {Roki.Nuvio.Settings.authorization_notice()}
          </p>

          <p :if={@nuvio.loading} class="flex items-center gap-2 text-sm text-base-content/60">
            <span class="loading loading-spinner loading-xs"></span> Reading the manifest…
          </p>
          <p
            :if={not @nuvio.loading and @nuvio.catalog != []}
            id="nuvio-count"
            class="text-sm text-base-content/60"
          >
            {length(@nuvio.catalog)} providers in the manifest. {nuvio_on_count(@nuvio.catalog)} on
            — {if nuvio_on_count(@nuvio.catalog) > Roki.Nuvio.max_providers(),
              do: "only the first #{Roki.Nuvio.max_providers()} are asked per search",
              else: "up to #{Roki.Nuvio.max_providers()} are asked per search"}.
          </p>
          <button
            :if={not @nuvio.loading and @nuvio.catalog == []}
            type="button"
            phx-click="nuvio_load"
            class="btn btn-sm btn-primary"
          >
            Load providers from the manifest
          </button>
          <p :if={match?({:ok, _}, @nuvio_msg)} class="text-sm text-success">{elem(@nuvio_msg, 1)}</p>
          <p :if={match?({:error, _}, @nuvio_msg)} class="text-sm text-error">
            {elem(@nuvio_msg, 1)}
          </p>

          <div class="max-h-[34rem] space-y-2 overflow-y-auto pr-1">
            <div
              :for={entry <- @nuvio.catalog}
              id={"nuvio-#{entry.provider.id}"}
              class={[
                "flex items-start gap-3 rounded-xl border border-base-300 bg-base-100/70 p-3",
                (entry.enabled and not entry.asked) && "opacity-60"
              ]}
            >
              <details class="min-w-0 flex-1">
                <summary class="flex cursor-pointer flex-wrap items-center gap-2 text-sm">
                  <span class="font-semibold">{entry.provider.name}</span>
                  <span class="text-xs text-base-content/50">{entry.provider.id}</span>
                  <span
                    :if={entry.enabled and not entry.asked}
                    class="badge badge-warning badge-sm"
                    title={"Only the first #{Roki.Nuvio.max_providers()} providers that are on are asked; the newest you switched on come first, then the defaults."}
                  >
                    not asked
                  </span>
                  <span :if={entry.default} class="badge badge-primary badge-sm badge-outline">
                    default
                  </span>
                  <span :if={entry.provider.has_settings} class="badge badge-ghost badge-sm">options</span>
                  <span :if={entry.provider.limited} class="badge badge-warning badge-sm">limited</span>
                  <span class="text-xs text-base-content/40">
                    {Enum.join(entry.provider.formats, " · ")}
                  </span>
                </summary>

                <p class="mt-2 text-sm text-base-content/60">{entry.provider.description}</p>

                <div :if={entry.provider.has_settings} class="mt-3 text-sm">
                  <button
                    type="button"
                    phx-click="nuvio_options"
                    phx-value-provider={entry.provider.id}
                    class="btn btn-xs btn-ghost"
                  >
                    Options
                  </button>
                </div>

                <%= if fields = @nuvio.schemas[entry.provider.id] do %>
                  <form
                    phx-submit="nuvio_save_options"
                    class="mt-3 space-y-2 border-t border-base-300 pt-3"
                  >
                    <input type="hidden" name="provider" value={entry.provider.id} />
                    <p :if={fields == []} class="text-xs text-base-content/50">
                      This provider has no options.
                    </p>
                    <%= for field <- fields do %>
                      <div
                        :if={field.type == :header}
                        class="pt-1 text-xs font-semibold uppercase tracking-wide text-base-content/50"
                      >
                        {field.label}
                      </div>
                      <label :if={field.type != :header} class="block space-y-1 text-sm">
                        <span class="font-medium">{field.label}</span>
                        <span :if={field.description} class="block text-xs text-base-content/50">
                          {field.description}
                        </span>
                        <%= case field.type do %>
                          <% :select -> %>
                            <select
                              name={"options[#{field.key}]"}
                              class="select select-bordered select-sm w-full"
                            >
                              <option
                                :for={option <- field.options}
                                value={option.value}
                                selected={
                                  option.value ==
                                    (Roki.Nuvio.Settings.options(@uuid, entry.provider.id)[field.key] ||
                                       field.default)
                                }
                              >
                                {option.label}
                              </option>
                            </select>
                          <% :toggle -> %>
                            <input
                              type="checkbox"
                              name={"options[#{field.key}]"}
                              value="true"
                              checked={
                                to_string(
                                  Roki.Nuvio.Settings.options(@uuid, entry.provider.id)[field.key] ||
                                    field.default
                                ) in ["true", "1"]
                              }
                              class="toggle toggle-sm"
                            />
                          <% _ -> %>
                            <input
                              type={if field.secret, do: "password", else: "text"}
                              name={"options[#{field.key}]"}
                              value={
                                if field.secret,
                                  do: "",
                                  else:
                                    to_string(
                                      Roki.Nuvio.Settings.options(@uuid, entry.provider.id)[field.key] ||
                                        field.default || ""
                                    )
                              }
                              placeholder={field.placeholder}
                              autocomplete="off"
                              spellcheck="false"
                              class="input input-bordered input-sm w-full"
                            />
                        <% end %>
                      </label>
                    <% end %>
                    <button class="btn btn-xs btn-primary">Save options</button>
                  </form>
                <% end %>
              </details>
              <input
                type="checkbox"
                role="switch"
                checked={entry.enabled}
                phx-click="nuvio_toggle"
                phx-value-provider={entry.provider.id}
                aria-label={"Use #{entry.provider.name}"}
                class="toggle toggle-success toggle-sm mt-0.5 shrink-0"
              />
            </div>
          </div>
        </section>

        <%!-- Torrents: a Real-Debrid or TorBox key, for an account that has none yet (and is not lent
             one). Once it has, the Connections section below is where keys are changed. --%>
        <section :if={not @debrid?} id="debrid" class="space-y-2 scroll-mt-4">
          <h2 class="text-xl font-semibold">Torrents — Real-Debrid or TorBox</h2>
          <p class="text-sm text-base-content/60">
            Torrent releases play through a debrid account (paid). Sign up at
            <a href="https://real-debrid.com" target="_blank" rel="noopener" class="link">real-debrid.com</a>
            or <a href="https://torbox.app" target="_blank" rel="noopener" class="link">torbox.app</a>
            (either one), copy your
            <a href="https://real-debrid.com/apitoken" target="_blank" rel="noopener" class="link">Real-Debrid API token</a>
            or <a href="https://torbox.app/settings" target="_blank" rel="noopener" class="link">TorBox API key</a>,
            and paste it here. It is checked with the service before it is kept.
          </p>
          <p class="text-sm"><span class="badge badge-ghost">Not connected</span></p>
          <form phx-submit="debrid_save" class="flex flex-wrap items-center gap-2">
            <input
              type="password"
              name="debrid[RD_TOKEN]"
              autocomplete="off"
              spellcheck="false"
              placeholder="Real-Debrid API token"
              class="input input-bordered input-sm w-full max-w-sm font-mono"
            />
            <input
              type="password"
              name="debrid[TORBOX_API_KEY]"
              autocomplete="off"
              spellcheck="false"
              placeholder="TorBox API key"
              class="input input-bordered input-sm w-full max-w-sm font-mono"
            />
            <button class="btn btn-sm btn-primary" disabled={@debrid_busy}>
              <span :if={@debrid_busy} class="loading loading-spinner loading-xs"></span> Connect
            </button>
          </form>
          <p :if={match?({:error, _}, @debrid_msg)} class="text-sm text-error">
            {elem(@debrid_msg, 1)}
          </p>
        </section>

        <section :if={@state == :ready} id="connections" class="space-y-1 scroll-mt-4">
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

          <%!-- OpenSubtitles lists files with just the key above; handing one over needs the account. --%>
          <form
            :if={@os.key?}
            id="os-login"
            phx-submit="save_os"
            class="space-y-2 pt-4"
            autocomplete="off"
          >
            <div class="font-medium">OpenSubtitles account</div>
            <p class="text-sm text-base-content/60">
              To download the subtitle files the player lists, OpenSubtitles needs the login of your
              account (free) as well as the key.
              <span :if={@os.user} class="text-success">Saved for {@os.user}.</span>
            </p>
            <div class="flex flex-wrap items-center gap-2">
              <input
                name="os[user]"
                value={@os.user}
                placeholder="username (not your email)"
                autocomplete="off"
                class="input input-bordered input-sm min-w-0 flex-1"
              />
              <input
                type="password"
                name="os[pass]"
                placeholder="password"
                autocomplete="new-password"
                class="input input-bordered input-sm min-w-0 flex-1"
              />
              <button type="submit" class="btn btn-sm btn-primary" disabled={@os_msg == :checking}>
                <span :if={@os_msg == :checking} class="loading loading-spinner loading-xs"></span>
                Save
              </button>
            </div>
            <p :if={match?({:ok, _}, @os_msg)} class="text-sm text-success">✓ {elem(@os_msg, 1)}</p>
            <p :if={match?({:error, _}, @os_msg)} class="text-sm text-error">{elem(@os_msg, 1)}</p>
          </form>
        </section>

        <.tmdb_section :if={@state == :ready} tmdb={@tmdb} username={@username} uploads={@uploads} />

        <.mal_section :if={@state == :ready} mal={@mal} />

        <.notify_section choices={@notify} />

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

          <div class="space-y-2 text-sm">
            <p class="text-base-content/70">
              To use the terminal app with this account, install <code>laev</code>, choose
              Settings → Cross-device sync, and paste your laev key there.
            </p>
            <button phx-click="show_key" class="btn btn-sm">
              {if @laev_key, do: "Hide my laev key", else: "Show my laev key"}
            </button>
            <div :if={@laev_key} class="flex items-center gap-2">
              <input
                id="laev-key"
                readonly
                value={@laev_key}
                onfocus="this.select()"
                class="input input-bordered input-sm min-w-0 flex-1 font-mono"
              />
              <button
                type="button"
                class="btn btn-sm"
                onclick="navigator.clipboard.writeText(document.getElementById('laev-key').value);this.textContent='Copied'"
              >
                Copy
              </button>
            </div>
            <p :if={@laev_key} class="text-xs text-base-content/60">
              Keep it private: it opens your synced history and, if you carry keys, your API keys.
            </p>
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

          <p class="text-sm text-base-content/60">
            <span :if={!@carrying?}>
              Changes here are saved instantly and apply on this site; they reach your terminal app
              only if you carry your keys above.
            </span>
            <span :if={@carrying? and @auto_sync == nil}>
              Changes are saved instantly and sent to your terminal app a few seconds later. No need
              to press anything.
            </span>
            <span :if={@carrying? and @auto_sync == :waiting}>Change saved — sending it on…</span>
            <span :if={@carrying? and @auto_sync == :syncing}>Sending your changes…</span>
            <span :if={@carrying? and @auto_sync == :done} class="text-success">
              ✓ Sent to your terminal app.
            </span>
            <span :if={@carrying? and @auto_sync == :failed} class="text-error">
              Couldn't reach the sync server; use Sync now to retry.
            </span>
          </p>

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

  defp external_app_spec(specs),
    do:
      Enum.filter(
        specs,
        &(elem(&1, 0) in [
            "play_from",
            "anime_audio",
            "browser_work",
            "external_app",
            "player_look",
            "sources_cache"
          ])
      )
      |> Enum.sort_by(
        &Enum.find_index(
          [
            "play_from",
            "anime_audio",
            "browser_work",
            "external_app",
            "player_look",
            "sources_cache"
          ],
          fn k ->
            k == elem(&1, 0)
          end
        )
      )

  attr :value, :string, required: true
  attr :saved, :any, default: nil

  defp device_row(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 py-3 sm:flex-row sm:items-center sm:gap-6">
      <label for="d-player" class="min-w-0 sm:w-1/2">
        <span class="font-medium">Player on this device</span>
        <span class="block text-xs text-base-content/60">
          What Play does on the title page. "Browser" plays here, up to 1080p. "External" hands the
          full release to VLC or another app: any resolution, nothing converted on the server. New
          accounts start on Browser. Remembered in this browser, so each of your devices has its own.
        </span>
      </label>
      <div class="flex items-center gap-2 sm:w-1/2">
        <select id="d-player" name="d[player]" class="select select-bordered w-full">
          <option value="external" selected={@value == "external"}>
            External player (default)
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
            {(@spec[:labels] || %{})[o] || o}{if o == @spec.default, do: " (default)"}
          </option>
        </select>
        <span :if={@saved == @key} class="shrink-0 text-sm text-success">Saved</span>
      </div>
    </div>
    """
  end

  # The site's browser cap sits right under laev's ceiling.
  defp web_rows_after("LAEV_MAX_RESOLUTION", specs),
    do:
      Enum.filter(specs, &(elem(&1, 0) in ["browser_max_resolution", "browser_max_size"]))
      |> Enum.sort()

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
        id: "s-" <> assigns.s.key,
        language?: assigns.s.key in @language_keys
      )

    assigns =
      if assigns.language? do
        # Unset means laev's own default: English.
        current = Roki.Languages.normalize(assigns.s.value) || "en"
        assign(assigns, current: current, choices: Roki.Languages.choices(current))
      else
        assigns
      end

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
        <select
          :if={@language?}
          id={@id}
          name={"s[#{@s.key}]"}
          disabled={@locked}
          class="select select-bordered w-full"
        >
          <option :if={@s.key == "LAEV_SUBS"} value="off" selected={@current == "off"}>
            Off — no subtitles
          </option>
          <option :for={{code, label} <- @choices.extra} value={code} selected>{label}</option>
          <optgroup label="Common">
            <option :for={{code, label} <- @choices.common} value={code} selected={@current == code}>
              {label}
            </option>
          </optgroup>
          <optgroup label="All languages">
            <option :for={{code, label} <- @choices.rest} value={code} selected={@current == code}>
              {label}
            </option>
          </optgroup>
        </select>
        <input
          :if={@s.type == :text and not @language?}
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

  attr :choices, :map, required: true

  # What to be told about. Friend requests and replies to your own comments always arrive.
  defp notify_section(assigns) do
    assigns = assign(assigns, :kinds, Roki.Notify.kinds())

    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">Notifications</h2>
      <p class="text-sm text-base-content/60">
        What the bell tells you. Friend requests and replies to your own comments always arrive.
      </p>
      <ul class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300">
        <li :for={{key, label, description, _default} <- @kinds} class="flex items-center gap-4 p-3">
          <div class="min-w-0 flex-1">
            <div class="font-medium">{label}</div>
            <div class="text-sm text-base-content/60">{description}</div>
          </div>
          <input
            type="checkbox"
            class="toggle toggle-primary"
            checked={Map.get(@choices, key, true)}
            phx-click="notify_toggle"
            phx-value-key={key}
            aria-label={label}
          />
        </li>
      </ul>
    </section>
    """
  end

  attr :tmdb, :map, required: true
  attr :username, :string, required: true
  attr :uploads, :map, required: true

  # TMDB: where film and show ratings are saved, on the person's own account.
  defp tmdb_section(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">TMDB</h2>

      <p :if={@tmdb.status == :loading} class="text-sm text-base-content/60">Checking…</p>

      <div :if={is_map(@tmdb.status) and @tmdb.status.linked?} class="space-y-2">
        <p>
          <span class="text-success">✓ Linked</span>
          <span :if={@tmdb.status.username}> as <strong>{@tmdb.status.username}</strong></span>
        </p>
        <p class="text-sm text-base-content/60">
          Your film and show ratings are saved on this TMDB account, and shown here from it.
        </p>
        <button
          phx-click="tmdb_logout"
          data-confirm="Unlink your TMDB account from this site? Your ratings stay on TMDB."
          class="btn btn-sm btn-ghost text-error"
        >
          Unlink
        </button>

        <form
          id="imdb-dates"
          phx-submit="imdb_dates"
          phx-change="imdb_validate"
          class="space-y-2 pt-3"
        >
          <p class="text-sm text-base-content/70">
            Brought your ratings over from IMDb? TMDB does not keep when you rated them, so they
            arrive with no date. Export them from IMDb (Your ratings → Export) and add the file
            here to date your watched titles by it.
          </p>
          <.live_file_input
            upload={@uploads.imdb_csv}
            class="file-input file-input-bordered file-input-sm w-full max-w-md"
          />
          <button type="submit" class="btn btn-sm btn-primary">Date my titles</button>
        </form>
      </div>

      <div :if={is_map(@tmdb.status) and not @tmdb.status.linked?} class="space-y-3">
        <p class="text-sm text-base-content/70">
          Film and show ratings are saved on your own TMDB account, so they stay yours. It is free:
          make one at themoviedb.org if you do not have one, then link it here. Each TMDB account
          can be linked by one person.
        </p>
        <a
          href={~p"/tmdb/link?#{[return: "/u/#{@username}/settings"]}"}
          class="btn btn-primary btn-sm"
        >
          Link my TMDB account
        </a>
      </div>

      <p :if={@tmdb.note} class="text-sm text-base-content/60">{@tmdb.note}</p>
    </section>
    """
  end

  attr :mal, :map, required: true

  # MyAnimeList: what anime ratings and watch progress go to once it is connected.
  defp mal_section(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">MyAnimeList</h2>

      <p :if={@mal.status == :loading} class="text-sm text-base-content/60">Checking…</p>

      <div :if={is_map(@mal.status) and @mal.status.connected?} class="space-y-2">
        <p>
          <span class="text-success">✓ Connected</span>
          <span :if={@mal.status.username}> as <strong>{@mal.status.username}</strong></span>
        </p>
        <p class="text-sm text-base-content/60">
          Anime you finish here is counted on your list, and anime is rated there instead of on TMDB.
        </p>
        <button
          phx-click="mal_logout"
          data-confirm="Disconnect MyAnimeList from this site?"
          class="btn btn-sm btn-ghost text-error"
        >
          Disconnect
        </button>
      </div>

      <div :if={is_map(@mal.status) and not @mal.status.connected?} class="space-y-3">
        <p :if={not @mal.status.configured?} class="text-sm text-base-content/70">
          MyAnimeList is not set up on this site yet. Add your MyAnimeList client ID under Connections first.
        </p>

        <div :if={@mal.status.configured?} class="space-y-3">
          <p class="text-sm text-base-content/60">
            Not connected. Connecting lets this site count the anime you finish on your list and rate
            on MyAnimeList.
          </p>

          <button :if={@mal.url == nil} phx-click="mal_start" class="btn btn-primary btn-sm">
            Connect MyAnimeList
          </button>

          <div :if={@mal.url} class="space-y-3 text-sm">
            <p>
              Open MyAnimeList, press <strong>Allow</strong>, and you come back here connected.
            </p>
            <a href={@mal.url} class="btn btn-sm btn-primary">
              Open MyAnimeList
            </a>
            <details class="text-base-content/70">
              <summary class="cursor-pointer">Didn't come back here?</summary>
              <p class="mt-2">
                If the browser showed an error page instead, copy the whole address it ended up on
                and paste it here.
              </p>
              <form
                id="mal-finish"
                phx-submit="mal_finish"
                class="mt-2 flex flex-wrap items-center gap-2"
              >
                <input
                  type="text"
                  name="pasted"
                  placeholder="…/mal/callback?code=…"
                  autocomplete="off"
                  autocapitalize="off"
                  spellcheck="false"
                  class="input input-bordered input-sm min-w-0 flex-1 font-mono"
                />
                <button type="submit" class="btn btn-sm btn-primary" disabled={@mal.busy}>
                  <span :if={@mal.busy} class="loading loading-spinner loading-xs"></span> Connect
                </button>
              </form>
            </details>
          </div>
        </div>
      </div>

      <p :if={@mal.error} class="text-sm text-error">{@mal.error}</p>
    </section>
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
