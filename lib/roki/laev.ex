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

  alias Laev.{Resume, Settings, Shelf, Stats, Sync, Watchlist}

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
  Run `fun` as the user when they are connected, else in the site's shared scope.
  A connected user searches with their own TMDB key and has their own marks to
  grey titles by; a visitor gets neither.
  """
  def run_as(nil, fun), do: shared(fun)
  def run_as(uuid, fun), do: if(connected?(uuid), do: run(uuid, fun), else: shared(fun))

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
             stats: Stats.all_time(),
             continue: mark_seen(continue_watching()),
             saved: mark_seen(saved()),
             keys: keys(),
             keys_carried?: Sync.keys_enabled?(),
             server: Sync.url()
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
  def sync(uuid), do: run(uuid, &Sync.sync/0)

  @doc "Forget the connection and everything pulled for this account."
  def disconnect(uuid) do
    File.rm_rf!(dir(uuid))
    :ok
  end

  @doc "Turn carrying API keys on or off for a connected account, then sync so it takes effect."
  def set_carry_keys(uuid, on?) do
    run(uuid, fn ->
      Settings.put("LAEV_SYNC_KEYS", if(on?, do: "on", else: "off"))
      Sync.sync()
    end)
  end

  @doc "A short, human reason for a failed connect."
  def explain({:bad_key, why}), do: why
  def explain({:bad_url, url}), do: "#{url} is not a usable server address"
  def explain({:http, 401}), do: "the server did not accept that key"
  def explain({:http, status}), do: "the server answered #{status}"
  def explain(other), do: "could not sync (#{inspect(other)})"

  def duration(seconds), do: Stats.duration(seconds)

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

  # Which services are connected — never the values; laev masks them and the
  # page has no use for them.
  defp keys do
    for {:keys, entries} <- Settings.groups(), e <- entries do
      %{label: e.label, key: e.key, set?: e.set?}
    end
  end

  defp poster(nil), do: nil
  defp poster(path), do: "https://image.tmdb.org/t/p/w342" <> path

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: String.trim(v)
end
