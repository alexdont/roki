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

  alias Laev.{MAL, Resume, Settings, Shelf, Sync, Watchlist}

  @doc "Where laev keeps state for accounts. `/root/laev-users` in the container — `data/` on the host."
  def base_dir do
    Application.get_env(:roki, :laev_dir) || Path.join(System.user_home!(), "laev-users")
  end

  @doc "The user's directory. Raises on anything that is not a uuid, so a path can never be built from user input."
  def dir(uuid) do
    {:ok, uuid} = Ecto.UUID.cast(uuid)
    Path.join(base_dir(), uuid)
  end

  def run(uuid, fun) do
    dir = dir(uuid)
    # Keys lent by the site owner (Roki.Keys) are added to this request's scope only, and only
    # where the account has none of its own.
    lent = Roki.Keys.overrides(uuid, Laev.Config.read_dir(dir))
    # (A study session's languages are laev scope overrides, which win over any of this.)
    try do
      dir |> Laev.Scope.load(Map.merge(lent, app_keys())) |> Laev.Scope.run(fun)
    after
      scrub_env()
    end
  end

  # The site's own settings, as the application started with them.
  @site_env [:tmdb_key, :mal_client_id, :mal_client_secret]

  @doc "Remember the site's own laev settings; `scrub_env/0` puts them back. Called once at start."
  def snapshot_env do
    :persistent_term.put(
      {__MODULE__, :site_env},
      for(k <- @site_env, v = Application.get_env(:laev, k), into: %{}, do: {k, v})
    )
  end

  @doc """
  Take every personal laev setting back out of the application environment.

  Laev writes the keys it restores from a sync into the *application* environment as well as the
  user's own, which is what every account falls back to when it has no key of its own. Left
  alone, whoever syncs their keys first hands them to everybody: one account's TMDB session
  (their ratings), debrid and TorBox keys. Nothing here reads that environment on purpose, so it
  is kept empty except for the site's own settings.
  """
  def scrub_env do
    site = :persistent_term.get({__MODULE__, :site_env}, %{})

    for key <- Map.values(Laev.Config.keys()) do
      want = Map.get(site, key)

      cond do
        Application.get_env(:laev, key) == want -> :ok
        is_nil(want) -> Application.delete_env(:laev, key)
        true -> Application.put_env(:laev, key, want)
      end
    end

    :ok
  end

  @doc "Run inside the site's own scope — no user, only the server-wide TMDB key."
  def shared(fun),
    do: Path.join(base_dir(), "_featured") |> Laev.Scope.load(app_keys()) |> Laev.Scope.run(fun)

  @doc """
  The keys the site itself provides to every account: its MyAnimeList app (`MAL_CLIENT_ID`, and
  `MAL_CLIENT_SECRET` if the app has one). They win over anything in an account's own config, so
  a stale or empty copy synced from a terminal can never shadow them. Empty when not configured.
  """
  def app_keys do
    for {config_key, laev_key} <- [
          mal_client_id: :mal_client_id,
          mal_client_secret: :mal_client_secret
        ],
        value = Application.get_env(:roki, config_key),
        value not in [nil, ""],
        into: %{},
        do: {laev_key, value}
  end

  @doc "Does the site provide the MyAnimeList app, so accounts need no client id of their own?"
  def site_mal?, do: Map.has_key?(app_keys(), :mal_client_id)

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
    for i <- items, seen?(i), not started_beyond_map?(i), into: MapSet.new(), do: {i.type, i.id}
  end

  # Laev calls an anime seen when every MyAnimeList entry it knows is. A season it does not know
  # yet, with episodes already marked, means there is more of the show to watch.
  defp started_beyond_map?(%{type: "tv", id: id}) when is_integer(id),
    do: Laev.AnimeMap.mal_ids("tv", id) != [] and unmapped_marks(id) > 0

  defp started_beyond_map?(_item), do: false

  def seen_keys(uuid, items) do
    if uuid && connected?(uuid), do: run(uuid, fn -> seen_keys(items) end), else: MapSet.new()
  end

  @doc """
  Titles with what this user has watched of them, for the posters: `partial: "2 seasons watched"`
  on the ones started but not finished (anime by MyAnimeList entry — a season is an entry
  whose episodes are all marked; a show by its marked episodes). A copy per user: the lists
  themselves are shared and never touched.
  """
  def annotate(uuid, items) do
    if uuid && connected?(uuid), do: run(uuid, fn -> partial(items) end), else: items
  end

  defp partial(items) do
    anime = Laev.Position.anime_marks()
    shows = Laev.Position.episode_marks()

    Enum.map(items, fn item ->
      item =
        if Laev.Watchlist.has?(item.type, item.id), do: Map.put(item, :saved, true), else: item

      case partial_text(item, anime, shows) do
        nil -> item
        text -> Map.put(item, :partial, text)
      end
    end)
  rescue
    _ -> items
  end

  defp partial_text(%{type: "tv", id: id}, anime, shows) when is_integer(id) do
    case Laev.AnimeMap.mal_ids("tv", id) do
      [] ->
        shows |> Map.get({"tv", id}, %{}) |> Map.values() |> Enum.sum() |> episodes_text()

      mals ->
        # A season MyAnimeList has no entry for (the cross-id list lags behind new seasons) is
        # marked per episode on TMDB's side: started there, the title is not finished.
        extra = unmapped_marks(id)
        done = Enum.count(mals, &(Laev.Position.mark_state(%{mal_id: &1}) == :watched))
        eps = mals |> Enum.map(&Map.get(anime, &1, 0)) |> Enum.sum()

        cond do
          done == length(mals) and extra > 0 ->
            "#{done} season#{if done > 1, do: "s"} + #{episodes_text(extra)}"

          done == length(mals) ->
            nil

          done > 0 ->
            "#{done} season#{if done > 1, do: "s"} watched"

          true ->
            episodes_text(eps)
        end
    end
  end

  defp partial_text(_item, _anime, _shows), do: nil

  # Episodes marked in seasons of an anime that the cross-id list has no MyAnimeList entry for.
  defp unmapped_marks(id) do
    Laev.Position.episode_marks()
    |> Map.get({"tv", id}, %{})
    |> Enum.filter(fn {season, _n} ->
      is_integer(season) and season > 0 and Laev.Anime.Parts.parts(id, season) == []
    end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
  end

  defp episodes_text(n) when n > 0, do: "#{n} ep#{if n > 1, do: "s"} watched"
  defp episodes_text(_), do: nil

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
             watchlist:
               watchlist()
               |> Map.new(fn {k, v} ->
                 {k, v |> mark_seen() |> then(&if(k == :behind, do: with_resume(&1), else: &1))}
               end),
             continue: continue_watching() |> mark_seen() |> with_resume(),
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
    url = opts |> Keyword.get(:url) |> blank_to_nil() || sync_url()
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

  @doc """
  First-time setup from the site: check the keys, make a laev key, connect with it (the server
  provisions any well-formed key), keep the keys carried so the terminal app gets them too.
  `keys` is `%{"RD_TOKEN" => …, "TORBOX_API_KEY" => …, "TMDB_API_KEY" => …}`; blanks are skipped.
  Nothing is left behind on failure.
  """
  def setup(uuid, keys) do
    Roki.Stats.forget(uuid)

    case run(uuid, fn -> Laev.Setup.first_run(keys) end) do
      {:ok, _} ->
        :ok

      {:error, :tmdb_key_required} ->
        {:error, "A TMDB key is needed to find titles."}

      {:error, :debrid_key_required} ->
        {:error, "Add a Real-Debrid or TorBox key — one of them is needed to play anything."}

      {:error, {key, why}} when is_binary(key) ->
        {:error, "#{key_name(key)}: #{explain(why)}"}

      {:error, reason} ->
        {:error, "Could not set up: " <> explain(reason)}
    end
  end

  defp key_name("RD_TOKEN"), do: "Real-Debrid"
  defp key_name("TORBOX_API_KEY"), do: "TorBox"
  defp key_name("TMDB_API_KEY"), do: "TMDB"
  defp key_name(other), do: other

  @doc """
  Set up an account that uses the site's keys: nothing to ask, so a laev key is made and the
  account connected to it. The keys themselves are not saved anywhere of its own and are never
  carried in its synced files.
  """
  def setup_granted(uuid) do
    Roki.Stats.forget(uuid)

    with {:ok, summary} <- connect(uuid, Laev.Setup.generate_key(), carry_keys?: false) do
      sync(uuid)
      {:ok, summary}
    end
  end

  @doc "The laev key to paste into the terminal app, for a connected account."
  def sync_key(uuid), do: run(uuid, fn -> Laev.Scope.get(:sync_token) end)

  @doc "This site's own sync store (`/api/laev`): where an account's laev key is kept unless it says otherwise."
  def sync_url, do: RokiWeb.Endpoint.url() <> "/api/laev"

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
    # 4K only reaches a browser that decodes the release's video itself (`Roki.Watch.browser_limit/2`).
    "browser_max_resolution" => %{
      default: "2160p",
      allowed: ~w(480p 720p 1080p 2160p),
      labels: %{"2160p" => "4K"}
    },
    # The largest release the browser player takes: each play is downloaded whole into the
    # server's cache (`Roki.Watch.size_cap/1`), so a 90 GB remux picked by accident costs real disk.
    "browser_max_size" => %{
      default: "40",
      allowed: ~w(10 20 40 80 off),
      labels: %{"10" => "10 GB", "20" => "20 GB", "40" => "40 GB", "80" => "80 GB", "off" => "No limit"}
    },
    # How long found sources are kept so the next Play skips the search.
    "sources_cache" => %{
      default: "12",
      allowed: ~w(off 6 12 24),
      labels: %{"off" => "Off", "6" => "6 hours", "12" => "12 hours", "24" => "24 hours"}
    },
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
  def settings(uuid) do
    all = run(uuid, fn -> Settings.all(:browser) end)

    # An account using the site's keys has none of its own to show or change.
    all = if Roki.Keys.granted?(uuid), do: Enum.reject(all, &(&1.group == :keys)), else: all

    # The site's MyAnimeList app is not the user's to set.
    if site_mal?(),
      do: Enum.reject(all, &(&1.key in ["MAL_CLIENT_ID", "MAL_CLIENT_SECRET"])),
      else: all
  end

  @doc "Change one setting (`:ok` | `{:error, reason}`). Laev checks the key and the value."
  def put_setting(uuid, key, value), do: run(uuid, fn -> Settings.put(key, value) end)

  # ── MyAnimeList ────────────────────────────────────────────────────

  @doc """
  The MyAnimeList connection of this user: `%{configured?, connected?, username}`. The login is
  laev's own (`mal.json` in the user's data directory), the one the terminal app uses.
  """
  def mal_status(uuid) do
    run(uuid, fn ->
      connected? = MAL.authenticated?()

      %{
        configured?: MAL.configured?(),
        connected?: connected?,
        username: if(connected?, do: MAL.username())
      }
    end)
  end

  @pending_ttl 15 * 60
  @mal_auth "https://myanimelist.net/v1/oauth2/authorize"
  @mal_token "https://myanimelist.net/v1/oauth2/token"

  @doc """
  Where MyAnimeList sends people back to once they approve: this site's own callback, which the
  site's MyAnimeList app has to name as its redirect URL. (The terminal app's own app names
  `localhost` instead; a MyAnimeList app has one redirect, so the site needs an app of its own.)
  """
  def mal_redirect, do: RokiWeb.Endpoint.url() <> "/mal/callback"

  @doc """
  Start a login: remember a fresh state and PKCE verifier, and return the address to approve at.
  MyAnimeList then sends the browser to `mal_redirect/0` with a code, and `mal_finish/2` is
  given it — by the callback, or pasted in by hand should the browser land elsewhere.
  """
  def mal_begin(uuid) do
    run(uuid, fn ->
      if MAL.configured?() do
        verifier = MAL.new_verifier()
        state = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

        File.write!(
          pending_path(),
          Jason.encode!(%{state: state, verifier: verifier, at: System.os_time(:second)})
        )

        {:ok, mal_authorize_url(state, verifier)}
      else
        {:error, "Add your MyAnimeList client ID under Connections first."}
      end
    end)
  end

  # laev's authorize address, with this site's redirect in place of the terminal app's.
  defp mal_authorize_url(state, verifier) do
    @mal_auth <>
      "?" <>
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => MAL.client_id(),
        "state" => state,
        "code_challenge" => verifier,
        "code_challenge_method" => "plain",
        "redirect_uri" => mal_redirect()
      })
  end

  @doc """
  Finish it with what MyAnimeList sent back: the callback's query (`?code=…&state=…`), the whole
  address, or just the code. `{:ok, username}` or `{:error, why}`.
  """
  def mal_finish(uuid, pasted) do
    run(uuid, fn ->
      with {:ok, pending} <- read_pending(),
           {:ok, code} <- pasted_code(pasted, pending["state"]),
           {:ok, _tokens} <- mal_exchange(code, pending["verifier"]) do
        File.rm(pending_path())
        {:ok, MAL.username() || "your account"}
      else
        {:error, {:mal, _status, _body}} ->
          {:error,
           "MyAnimeList did not accept that code. Codes work once and expire fast; start again."}

        {:error, why} when is_binary(why) ->
          {:error, why}

        _ ->
          {:error, "Could not connect. Start again."}
      end
    end)
  end

  # The code for tokens, naming this site's redirect (it has to be the one the approval named),
  # kept where laev keeps them (`mal.json` in the user's data directory), so the rest of laev's
  # MyAnimeList client — the refresh, the list, the ratings — applies as it is.
  defp mal_exchange(code, verifier) do
    body = %{
      "grant_type" => "authorization_code",
      "client_id" => MAL.client_id(),
      "code" => code,
      "code_verifier" => verifier,
      "redirect_uri" => mal_redirect()
    }

    body =
      case MAL.client_secret() do
        s when is_binary(s) and s != "" -> Map.put(body, "client_secret", s)
        _ -> body
      end

    case Req.post(@mal_token, form: body, retry: false, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"access_token" => at} = b}} ->
        data = %{
          "access_token" => at,
          "refresh_token" => b["refresh_token"],
          "expires_at" => System.os_time(:second) + (b["expires_in"] || 2_400_000)
        }

        File.write(Path.join(Laev.Scope.dir(), "mal.json"), Jason.encode!(data))
        {:ok, data}

      {:ok, %{status: s, body: b}} ->
        {:error, {:mal, s, inspect(b)}}

      {:error, e} ->
        {:error, e}
    end
  end

  @doc "Forget the MyAnimeList login."
  def mal_logout(uuid), do: run(uuid, fn -> MAL.logout() end)

  defp pending_path, do: Path.join(Laev.Scope.dir(), "mal-pending.json")

  defp read_pending do
    with {:ok, body} <- File.read(pending_path()),
         {:ok, %{"at" => at} = pending} <- Jason.decode(body),
         true <- System.os_time(:second) - at < @pending_ttl do
      {:ok, pending}
    else
      _ -> {:error, "That login attempt has expired. Press Connect again."}
    end
  end

  defp pasted_code(pasted, state) do
    text = pasted |> to_string() |> String.trim()

    query =
      case String.split(text, "?", parts: 2) do
        [_, q] -> URI.decode_query(q)
        _ -> %{}
      end

    cond do
      text == "" ->
        {:error, "Paste the address from the browser first."}

      query["error"] ->
        {:error, "MyAnimeList said: #{query["error"]}."}

      is_binary(query["code"]) and query["state"] not in [nil, state] ->
        {:error, "That address belongs to a different attempt. Press Connect again."}

      is_binary(query["code"]) ->
        {:ok, query["code"]}

      not String.contains?(text, ["?", "/", " "]) ->
        {:ok, text}

      true ->
        {:error, "No code found in that. Copy the whole address, it contains code=…"}
    end
  end

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
    case run(uuid, fn -> Laev.Setup.replace_key(key, value) end) do
      {:ok, detail} ->
        Roki.Stats.forget(uuid)
        {:ok, detail}

      {:error, :empty} ->
        {:error, "paste the key first"}

      other ->
        other
    end
  end

  @doc """
  The OpenSubtitles account: searching needs only the API key, but downloading a file is done
  as a logged-in user. `%{key?: bool, user: name | nil, login?: bool}` (the password is never read back).
  """
  def os_login(uuid) do
    run(uuid, fn ->
      user = Laev.Scope.get(:opensubtitles_username)

      %{
        key?: Laev.OpenSubtitles.configured?(),
        user: if(user in [nil, ""], do: nil, else: user),
        login?: Laev.OpenSubtitles.can_download?()
      }
    end)
  end

  @doc "Save the OpenSubtitles login once the service accepts it. `:ok` or `{:error, why}`."
  def put_os_login(uuid, user, pass) do
    user = String.trim(user || "")
    pass = String.trim(pass || "")

    run(uuid, fn ->
      with :ok <- Laev.OpenSubtitles.verify_login(user, pass),
           :ok <- Settings.put("OPENSUBTITLES_USERNAME", user),
           :ok <- Settings.put("OPENSUBTITLES_PASSWORD", pass) do
        Roki.Stats.forget(uuid)
        :ok
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

  # Where each in-progress title was left: `resume_at` seconds (the same number the terminal
  # app resumes from; under half a minute is the beginning and not worth showing) and, when
  # laev knows how long the film or an episode runs, `runtime`, for "37 min left".
  defp with_resume(items) do
    runtimes = Laev.Stats.known_runtimes()
    Enum.map(items, &Map.merge(&1, resume_info(&1, runtimes)))
  end

  defp resume_info(%{type: type, id: id} = item, runtimes) when type in ["movie", "tv"] do
    entry = Resume.get(type, id) || %{}

    ctx = %{
      type: type,
      tmdb_id: id,
      season: entry["season"],
      episode: entry["episode"],
      mal_id: item[:mal_id] || entry["mal_id"]
    }

    case Laev.Position.saved_position(ctx) do
      secs when is_integer(secs) and secs >= 30 ->
        %{resume_at: secs, runtime: runtime_of(item, ctx, runtimes)}

      _ ->
        %{}
    end
  end

  defp resume_info(_item, _runtimes), do: %{}

  defp runtime_of(_item, %{type: "movie", tmdb_id: id}, rt), do: rt["movie-#{id}"]

  defp runtime_of(_item, %{mal_id: mal} = ctx, rt) when is_integer(mal),
    do: rt["mal-#{mal}"] || rt["tv-#{ctx.tmdb_id}"]

  defp runtime_of(_item, ctx, rt), do: rt["tv-#{ctx.tmdb_id}"]

  @doc """
  Episodes watched out of all episodes, for shows the shelf counts in seasons ("1/3 seasons
  watched"): `%{{"tv", id} => {watched, total}}`. The watched side is laev's own marks; the
  total is the aired seasons' episode counts from TMDB (a show is looked up once and
  remembered, `Roki.Watch.title/3`). Slow the first time, so the page asks for it after the
  shelf is already drawn. Anime and shows noted in episodes already have their own count.
  """
  def episode_progress(uuid, items) do
    wanted =
      items
      |> Enum.filter(&(&1.type == "tv" and &1[:anime] != true and season_note?(&1[:note])))
      |> Enum.uniq_by(& &1.id)

    if wanted == [] do
      %{}
    else
      marks = run(uuid, &Laev.Position.episode_marks/0)
      today = Date.utc_today()

      wanted
      |> Task.async_stream(&{&1.id, total_episodes(uuid, &1.id, today)},
        max_concurrency: 4,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {id, total}}, acc when is_integer(total) and total > 0 ->
          done = marks |> Map.get({"tv", id}, %{}) |> Map.values() |> Enum.sum()
          Map.put(acc, {"tv", id}, {min(done, total), total})

        _other, acc ->
          acc
      end)
    end
  end

  defp season_note?(note) when is_binary(note), do: note =~ ~r/\d+\s*\/\s*\d+\s+seasons/
  defp season_note?(_note), do: false

  defp total_episodes(uuid, id, today) do
    case Roki.Watch.title("tv", id, uuid) do
      {:ok, t} ->
        t.seasons
        |> Enum.filter(&(&1.number > 0 and aired?(&1.air_date, today)))
        |> Enum.map(&(&1.episodes || 0))
        |> Enum.sum()

      _ ->
        nil
    end
  end

  defp aired?(date, today) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> Date.compare(d, today) != :gt
      _ -> false
    end
  end

  defp aired?(_date, _today), do: false

  @doc """
  Everything this user has finished, newest first, as poster items — the record behind the
  home page's Completed section. Dates come from laev (`dated?: false` means it has none and
  the row must not claim one). Anime is marked by MyAnimeList entry; it is mapped to the TMDB
  show and season it belongs to so the poster opens the right page. Posters come from the cards
  laev already holds, so this makes no requests.
  """
  def completed(uuid) do
    run(uuid, fn ->
      rows = Laev.Shelf.completed() |> Enum.map(&completed_target/1)
      keys = for {_row, {type, id, _season}} <- rows, type != nil, do: {type, id}
      cards = Laev.Cards.get_many(Enum.uniq(keys))

      Enum.map(rows, fn {row, {type, id, season}} ->
        card = type && Map.get(cards, {type, id})

        %{
          type: type,
          id: id,
          season: season,
          mal_id: row.mal_id,
          title: row.title,
          poster: card && poster(card["poster_path"]),
          anime: row.kind == :anime,
          at: row.at,
          dated?: row.dated?
        }
      end)
    end)
  end

  @doc """
  Posters for the finished titles being shown that laev has no card for yet: read from TMDB
  once each (laev remembers the card), eight at a time. `%{{type, id} => poster_url}`.
  """
  def completed_posters(uuid, items) do
    keys =
      for %{type: type, id: id, poster: nil} <- items, type != nil, uniq: true, do: {type, id}

    if keys == [] do
      %{}
    else
      run(uuid, fn ->
        keys
        |> Laev.Shelf.load_cards(fn _ -> :ok end)
        |> Map.new(fn {key, card} -> {key, poster(card["poster_path"])} end)
      end)
    end
  end

  defp completed_target(%{type: "mal", mal_id: mal} = row) do
    case Laev.AnimeMap.tmdb(mal) do
      {"tv", id, season} -> {row, {"tv", id, season}}
      {"movie", id} -> {row, {"movie", id, nil}}
      _ -> {row, {nil, nil, nil}}
    end
  end

  defp completed_target(%{type: type, id: id} = row), do: {row, {type, id, nil}}

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
