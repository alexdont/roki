defmodule Roki.Laev do
  @moduledoc """
  A user's laev, as roki holds it.

  Laev is a library with a per-user scope: a directory for the user's state and
  the keys to the services they have connected. Roki gives every account its own
  directory (`<laev_dir>/<user uuid>`) and nothing is shared between accounts.
  An account starts out *not connected*; connecting is something the user does
  on the home page, by pasting their own laev key. Laev itself saves the
  connection in that directory (`config`, mode 600) — roki keeps no copy of the
  key anywhere else, which is why there is no table behind this module.

  Every function takes the PhoenixKit user uuid and runs inside that user's
  scope. The scope is bound to the calling process, so these are meant to be
  called from a task (`start_async`), never from a process shared between users.
  """

  alias Laev.{Resume, Settings, Shelf, Sync, Watchlist}

  @doc "Where laev keeps state for accounts. `/root/laev-users` in the container — `data/` on the host."
  def base_dir do
    Application.get_env(:roki, :laev_dir) || Path.join(System.user_home!(), "laev-users")
  end

  @doc "The user's directory. Raises on anything that is not a uuid, so a path can never be built from user input."
  def dir(uuid) do
    {:ok, uuid} = Ecto.UUID.cast(uuid)
    Path.join(base_dir(), uuid)
  end

  def run(uuid, fun), do: uuid |> dir() |> Laev.Scope.load() |> Laev.Scope.run(fun)

  @doc "Run inside the site's own scope — no user, only the server-wide TMDB key."
  def shared(fun),
    do: Path.join(base_dir(), "_featured") |> Laev.Scope.load() |> Laev.Scope.run(fun)

  @doc "Has this account chosen to connect laev? (Nothing is created on disk to find out.)"
  def connected?(uuid), do: File.exists?(Path.join(dir(uuid), "config"))

  @doc """
  Run `fun` in the scope that should talk to TMDB for public data: the site's own
  when it has a server-wide key, else the connected user's (their carried key),
  else the site's — which will say it has no key. Results here are the same for
  everyone, so the scope only decides whose key pays.
  """
  def public(uuid, fun) do
    cond do
      Roki.Featured.configured?() -> shared(fun)
      uuid && connected?(uuid) -> run(uuid, fun)
      true -> shared(fun)
    end
  end

  @doc """
  Which of these titles has this user seen — `{type, id}` pairs. Laev's own rule:
  a film once it is played through (or marked), a series only when marked
  watched, an anime when every MAL entry for it is. Empty for anyone not
  connected. Call from inside the scope when you already have one.
  """
  def seen_keys(items) do
    for i <- items, seen?(i), into: MapSet.new(), do: {i.type, i.id}
  end

  def seen_keys(uuid, items) do
    if uuid && connected?(uuid), do: run(uuid, fn -> seen_keys(items) end), else: MapSet.new()
  end

  defp seen?(item) do
    Shelf.seen?(item)
  rescue
    _ -> false
  end

  @doc """
  Everything the home page draws, in one pass — `:not_connected` when the user
  has never connected (and nothing is created on disk for them).
  """
  def overview(uuid) do
    if File.exists?(Path.join(dir(uuid), "config")) do
      run(uuid, fn ->
        if Sync.enabled?() do
          # Laev never downloads this during a lookup, and without it no anime can
          # be matched to a TMDB title — every in-progress anime silently drops off
          # the watchlist. One download per account, then it is just a file.
          Laev.AnimeMap.ensure()

          {:ok,
           %{
             tally: Shelf.tally(),
             watchlist: watchlist() |> Map.new(fn {k, v} -> {k, mark_seen(v)} end),
             continue: mark_seen(continue_watching()),
             saved: mark_seen(saved())
           }}
        else
          :not_connected
        end
      end)
    else
      :not_connected
    end
  end

  @doc """
  Connect to a laev key and pull what it holds. `carry_keys?` also brings the
  encrypted API keys across (Real-Debrid, TorBox, TMDB) — off unless the user
  asks, because it puts working debrid credentials on this server.
  """
  def connect(uuid, key, opts \\ []) do
    carry? = Keyword.get(opts, :carry_keys?, false)
    url = opts |> Keyword.get(:url) |> blank_to_nil()
    Roki.Stats.forget(uuid)

    run(uuid, fn ->
      if carry?, do: Settings.put("LAEV_SYNC_KEYS", "on")

      case Sync.connect(String.trim(key), url) do
        {:ok, summary} ->
          {:ok, summary}

        {:error, reason} ->
          # Don't leave the carry-keys switch on for a connection that failed.
          if carry?, do: Settings.put("LAEV_SYNC_KEYS", "off")
          {:error, reason}
      end
    end)
  end

  @doc "Pull, merge and push once."
  def sync(uuid) do
    result = run(uuid, &Sync.sync/0)
    Roki.Stats.forget(uuid)
    result
  end

  @doc "Forget the connection and everything pulled for this account."
  def disconnect(uuid) do
    Roki.Stats.forget(uuid)
    File.rm_rf!(dir(uuid))
    :ok
  end

  @doc "Turn carrying API keys on or off for a connected account, then sync so it takes effect."
  def set_carry_keys(uuid, on?) do
    Roki.Stats.forget(uuid)

    run(uuid, fn ->
      Settings.put("LAEV_SYNC_KEYS", if(on?, do: "on", else: "off"))
      Sync.sync()
    end)
  end

  # ── settings ───────────────────────────────────────────────────────

  # Settings that exist only on this site (laev has no such thing), kept beside the account's
  # laev state. Disconnecting laev removes them with the rest of the directory.
  @web_settings %{
    "browser_max_resolution" => %{default: "1080p", allowed: ~w(480p 720p 1080p)},
    # The app Play opens when the device uses an external player.
    "external_app" => %{
      default: "vlc",
      allowed: ~w(vlc infuse mpv m3u),
      labels: %{
        "vlc" => "VLC",
        "infuse" => "Infuse",
        "mpv" => "mpv",
        "m3u" => "Download .m3u file"
      }
    }
  }

  @doc "The site-only settings, defaults filled in: `%{\"browser_max_resolution\" => \"1080p\"}`."
  def web_settings(uuid) do
    saved =
      with {:ok, body} <- File.read(web_path(uuid)),
           {:ok, %{} = map} <- Jason.decode(body) do
        map
      else
        _ -> %{}
      end

    Map.new(@web_settings, fn {key, %{default: default, allowed: allowed}} ->
      value = saved[key]
      {key, if(value in allowed, do: value, else: default)}
    end)
  end

  @doc "What each site-only setting may be: `%{key => %{default:, allowed:}}`."
  def web_setting_specs, do: @web_settings

  @doc "Change one site-only setting. `:ok` or `{:error, reason}`."
  def put_web_setting(uuid, key, value) do
    case @web_settings[key] do
      %{allowed: allowed} ->
        if value in allowed do
          File.mkdir_p!(dir(uuid))
          merged = Map.put(web_settings(uuid), key, value)
          File.write!(web_path(uuid), Jason.encode!(merged))
          :ok
        else
          {:error, "not one of #{Enum.join(allowed, ", ")}"}
        end

      nil ->
        {:error, "unknown setting"}
    end
  end

  defp web_path(uuid), do: Path.join(dir(uuid), "roki-web.json")

  @doc "Every laev setting with this user's value; secrets come back masked, never in full."
  def settings(uuid), do: run(uuid, fn -> Settings.all(:browser) end)

  @doc "Change one setting (`:ok` | `{:error, reason}`). Laev checks the key and the value."
  def put_setting(uuid, key, value), do: run(uuid, fn -> Settings.put(key, value) end)

  @doc "Ask the service whether the key this user has saved still works."
  def check_key(uuid, key) do
    run(uuid, fn ->
      case Settings.get(key) do
        v when v in [nil, ""] -> {:error, "not set"}
        value -> Settings.validate(key, value)
      end
    end)
  end

  @doc """
  Save a key only if the service accepts it. `{:ok, detail}` with what the service
  said about the account (plan, days left), or `{:error, why}` with nothing saved.
  """
  def replace_key(uuid, key, value) do
    value = String.trim(value)

    run(uuid, fn ->
      with true <- value != "" or {:error, "paste the key first"},
           {:ok, detail} <- Settings.validate(key, value),
           :ok <- Settings.put(key, value) do
        Roki.Stats.forget(uuid)
        {:ok, detail}
      else
        {:error, reason} -> {:error, reason}
        other -> other
      end
    end)
  end

  @doc "Forget a saved key."
  def remove_key(uuid, key) do
    Roki.Stats.forget(uuid)
    put_setting(uuid, key, "")
  end

  @doc "What the sync server holds for this user: `{:ok, %{watchlist: 38, …}}` or why not."
  def sync_status(uuid), do: run(uuid, &Sync.check/0)

  @doc "Whether this user carries their API keys in the laev key."
  def carrying_keys?(uuid), do: run(uuid, &Sync.keys_enabled?/0)

  @doc "The server the laev key syncs with."
  def sync_server(uuid), do: run(uuid, &Sync.url/0)

  @doc "A short, human reason for a failed connect."
  def explain({:bad_key, why}), do: why
  def explain({:bad_url, url}), do: "#{url} is not a usable server address"
  def explain({:http, 401}), do: "the server did not accept that key"
  def explain({:http, status}), do: "the server answered #{status}"
  def explain({:must_be_one_of, _key, allowed}), do: "must be one of: #{Enum.join(allowed, ", ")}"
  def explain({:must_be_text, _key}), do: "must be text"
  def explain({:unknown_setting, key}), do: "#{key} is not a setting"
  def explain(reason) when is_binary(reason), do: reason
  def explain(other), do: "could not sync (#{inspect(other)})"

  def duration(seconds), do: Laev.Stats.duration(seconds)

  # ── what the page shows ────────────────────────────────────────────

  # Laev's own Watchlist: what you are in the middle of, most recently watched
  # first, then the shows you are caught up on, then the ones on hold. `rows/0`
  # marks the boundaries with `:caught_up` / `:on_hold` atoms between the maps.
  defp watchlist do
    {sections, _} =
      Enum.reduce(Shelf.rows(), {%{behind: [], caught_up: [], on_hold: []}, :behind}, fn
        row, {acc, section} when is_map(row) ->
          {Map.update!(acc, section, &[watch_item(row) | &1]), section}

        marker, {acc, _section} when marker in [:caught_up, :on_hold] ->
          {acc, marker}

        _other, state ->
          state
      end)

    Map.new(sections, fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  # `seen: true` greys a title out — laev's own "watched" rule, from the synced marks.
  defp mark_seen(items) do
    seen = seen_keys(items)
    Enum.map(items, &Map.put(&1, :seen, MapSet.member?(seen, {&1.type, &1.id})))
  end

  defp watch_item(row) do
    %{
      type: row.type,
      id: row.id,
      mal_id: row[:mal_id],
      title: row.title || "Untitled",
      year: row[:year],
      poster: row[:poster],
      note: row[:note],
      anime: row[:mal_id] != nil
    }
  end

  # Laev keeps title, poster and the season/episode you are on in the resume
  # record itself, so this needs no TMDB key.
  defp continue_watching do
    Resume.all()
    |> Enum.sort_by(&(&1["updated_at"] || 0), :desc)
    |> Enum.take(120)
    |> Enum.map(fn e ->
      %{
        type: e["type"],
        id: e["tmdb_id"],
        title: e["title"] || "Untitled",
        poster: poster(e["poster_path"]),
        season: e["season"],
        episode: e["episode"],
        anime: e["anime"] == true,
        mal_id: e["mal_id"],
        at: e["updated_at"]
      }
    end)
  end

  defp saved do
    Watchlist.all()
    |> Enum.sort_by(&(&1["added_at"] || 0), :desc)
    |> Enum.to_list()
    |> Enum.map(fn e ->
      %{
        type: e["type"],
        id: e["tmdb_id"],
        title: e["title"] || "Untitled",
        year: e["year"],
        poster: e["poster"]
      }
    end)
  end

  defp poster(nil), do: nil
  defp poster(path), do: "https://image.tmdb.org/t/p/w342" <> path

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: String.trim(v)
end
