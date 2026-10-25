defmodule Roki.Keys do
  @moduledoc """
  Lending the site owner's API keys to chosen accounts.

  An account the owner has granted needs no keys of its own: when its scope is built
  (`Roki.Laev.run/2`) the keys it is missing are filled in from the owner's. They exist only in
  that request's memory — never written to the account's own config, never in its synced files,
  never on its settings page — so nothing a borrower can reach contains them. Taking the grant
  away takes effect on the next request.

  Every use of a borrowed key is counted per account per day (`record/3`), which is what the admin
  page "API access" shows: who uses it, how much, and who is idle. An account can also be capped
  to a number of plays a day.
  """

  import Ecto.Query

  alias Roki.Repo
  alias Roki.TTLCache

  # The keys that can be lent, by their config names. The owner picks which are (see `shared/0`).
  @shareable ~w(RD_TOKEN TORBOX_API_KEY TMDB_API_KEY OPENSUBTITLES_API_KEY OPENSUBTITLES_USERNAME
                OPENSUBTITLES_PASSWORD JIMAKU_API_KEY)

  # What a use of a key weighs when accounts are ranked: a play or a download costs more than
  # checking one release.
  @weights %{"search" => 2, "probe" => 1, "play" => 5, "subtitle" => 3}

  def shareable, do: @shareable

  # What an account can be allowed, one by one: a permission and the config keys it covers.
  @permissions [
    {"RD_TOKEN", "Real-Debrid", ~w(RD_TOKEN)},
    {"TORBOX_API_KEY", "TorBox", ~w(TORBOX_API_KEY)},
    {"TMDB_API_KEY", "TMDB", ~w(TMDB_API_KEY)},
    {"OPENSUBTITLES", "OpenSubtitles",
     ~w(OPENSUBTITLES_API_KEY OPENSUBTITLES_USERNAME OPENSUBTITLES_PASSWORD)},
    {"JIMAKU_API_KEY", "Jimaku", ~w(JIMAKU_API_KEY)}
  ]

  @doc "`[{permission, label, config names}]` — the keys that can be allowed to an account one at a time."
  def permissions, do: @permissions

  @doc "The config names behind a list of permissions."
  def names_for(perms),
    do: for({id, _, names} <- @permissions, id in perms, name <- names, do: name)

  def kinds, do: Map.keys(@weights)

  defp grants, do: "roki_key_grants"
  defp usage, do: "roki_key_usage"
  defp settings, do: "roki_key_settings"

  # ── who may use the keys ───────────────────────────────────────────

  @doc "The grant for this account, `%{daily_plays, note}`, or nil. Remembered for a few seconds."
  def grant(uuid) when is_binary(uuid) do
    case TTLCache.fetch({:key_grant, uuid}, 15, fn -> load_grant(uuid) end) do
      {:ok, false} -> nil
      {:ok, grant} -> grant
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    # The database not being there (a test without one, a restart) is "no grant", never a crash
    # of whatever was only trying to build a scope.
    :exit, _ -> nil
  end

  def grant(_), do: nil

  @doc """
  May this account play in the browser? A browser play can make the server convert the video, which
  is the heavy part of it, so it is for the owner and the accounts they allowed; everyone else
  uses an external player (VLC, mpv), which costs the server nothing.
  """
  def browser?(uuid) when is_binary(uuid) do
    config().owner_uuid == uuid or match?(%{browser: true}, grant(uuid))
  end

  def browser?(_), do: false

  @doc "Does this account use any of the owner's keys?"
  def granted?(uuid), do: match?(%{keys: [_ | _]}, grant(uuid))

  defp load_grant(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    found =
      from(g in grants(),
        where: g.user_uuid == ^bin,
        select: %{daily_plays: g.daily_plays, note: g.note, keys: g.keys, browser: g.browser}
      )
      |> Repo.one()

    {:ok, found || false}
  end

  @doc "Let this account use all of the owner's keys and play in the browser."
  def grant!(uuid, daily_plays \\ nil) do
    set_access!(uuid, %{keys: for({id, _, _} <- @permissions, do: id), browser: true})

    if daily_plays, do: set_daily_plays!(uuid, daily_plays)
    :ok
  end

  @doc """
  Set what an account may use: `keys` (permission ids, see `permissions/0`) and `browser`.
  An account left with neither has no row at all.
  """
  def set_access!(uuid, %{keys: keys, browser: browser}) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    keys = Enum.filter(keys, &(&1 in Enum.map(@permissions, fn {id, _, _} -> id end)))

    if keys == [] and not browser do
      Repo.delete_all(from(g in grants(), where: g.user_uuid == ^bin))
    else
      Repo.insert_all(
        grants(),
        [
          %{
            user_uuid: bin,
            granted_at: DateTime.utc_now() |> DateTime.truncate(:second),
            keys: keys,
            browser: browser
          }
        ],
        on_conflict: {:replace, [:keys, :browser]},
        conflict_target: [:user_uuid]
      )
    end

    forget(uuid)
    :ok
  end

  @doc "Take everything back: the keys and the browser player."
  def revoke!(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    Repo.delete_all(from(g in grants(), where: g.user_uuid == ^bin))
    forget(uuid)
    :ok
  end

  @doc "Cap an account to this many plays a day (nil for no cap)."
  def set_daily_plays!(uuid, plays) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    Repo.update_all(from(g in grants(), where: g.user_uuid == ^bin), set: [daily_plays: plays])
    forget(uuid)
    :ok
  end

  defp forget(uuid), do: TTLCache.delete({:key_grant, uuid})

  @doc "Every account with any access: `%{uuid => %{daily_plays, granted_at, keys, browser}}`."
  def all_grants do
    from(g in grants(),
      select:
        {g.user_uuid,
         %{daily_plays: g.daily_plays, granted_at: g.granted_at, keys: g.keys, browser: g.browser}}
    )
    |> Repo.all()
    |> Map.new(fn {bin, g} -> {Ecto.UUID.load!(bin), g} end)
  end

  # ── whose keys, and which ──────────────────────────────────────────

  @doc "`%{owner_uuid: uuid | nil, shared: [config names]}`."
  def config do
    case TTLCache.fetch(:key_config, 30, fn -> {:ok, load_config()} end) do
      {:ok, config} -> config
      _ -> %{owner_uuid: nil, shared: @shareable}
    end
  end

  defp load_config do
    row =
      from(s in settings(), where: s.id == 1, select: %{owner: s.owner_uuid, shared: s.shared})
      |> Repo.one()

    case row do
      nil ->
        %{owner_uuid: nil, shared: @shareable}

      %{owner: owner, shared: shared} ->
        %{owner_uuid: owner && Ecto.UUID.load!(owner), shared: shared}
    end
  end

  def save_config!(owner_uuid, shared) do
    shared = Enum.filter(shared, &(&1 in @shareable))
    {:ok, owner} = if owner_uuid, do: Ecto.UUID.dump(owner_uuid), else: {:ok, nil}

    Repo.insert_all(settings(), [%{id: 1, owner_uuid: owner, shared: shared}],
      on_conflict: {:replace, [:owner_uuid, :shared]},
      conflict_target: [:id]
    )

    TTLCache.delete(:key_owner_keys)
    TTLCache.delete(:key_config)
    :ok
  end

  # The lent keys as laev's scope names (`:rd_token`, …), read from the owner's own config.
  defp owner_keys do
    case TTLCache.fetch(:key_owner_keys, 30, fn -> {:ok, read_owner_keys()} end) do
      {:ok, keys} -> keys
      _ -> %{}
    end
  end

  defp read_owner_keys do
    %{owner_uuid: owner, shared: shared} = config()

    if owner do
      atoms = for name <- shared, atom = Map.get(Laev.Config.keys(), name), do: atom
      owner |> Roki.Laev.dir() |> Laev.Config.read_dir() |> Map.take(atoms)
    else
      %{}
    end
  end

  @doc """
  The keys to add to this account's scope: the lent ones it has none of itself. `own` is what its
  own config holds. Nothing for an account without a grant, or for the owner.
  """
  def overrides(uuid, own) do
    cond do
      not granted?(uuid) ->
        %{}

      config().owner_uuid == uuid ->
        %{}

      true ->
        allowed =
          for name <- names_for(grant(uuid).keys),
              atom = Map.get(Laev.Config.keys(), name),
              do: atom

        for {k, v} <- owner_keys(), k in allowed, own[k] in [nil, ""], into: %{}, do: {k, v}
    end
  rescue
    _ -> %{}
  end

  # ── counting what the keys are used for ────────────────────────────

  @doc "Count a use of the lent keys (`:search`, `:probe`, `:play`, `:subtitle`) — only for an account that has a grant."
  def record(uuid, kind, n \\ 1) when kind in [:search, :probe, :play, :subtitle] and n > 0 do
    if granted?(uuid) do
      {:ok, bin} = Ecto.UUID.dump(uuid)

      Repo.insert_all(
        usage(),
        [%{user_uuid: bin, day: Date.utc_today(), kind: Atom.to_string(kind), count: n}],
        on_conflict: [inc: [count: n]],
        conflict_target: [:user_uuid, :day, :kind]
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "May this account start another play today? (`false` once it has used its daily plays.)"
  def allow_play?(uuid) do
    case grant(uuid) do
      %{daily_plays: cap} when is_integer(cap) -> plays_today(uuid) < cap
      _ -> true
    end
  end

  def plays_today(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    today = Date.utc_today()

    from(u in usage(),
      where: u.user_uuid == ^bin and u.day == ^today and u.kind == "play",
      select: sum(u.count)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  What each account did over the last `days` days, heaviest first:
  `[%{uuid, today, week, total, kinds: %{"play" => n, …}, last_day, score}]`.
  """
  def stats(days \\ 30) do
    since = Date.add(Date.utc_today(), -(days - 1))
    today = Date.utc_today()
    week = Date.add(today, -6)

    from(u in usage(), where: u.day >= ^since, select: {u.user_uuid, u.day, u.kind, u.count})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {bin, rows} ->
      kinds =
        Enum.reduce(rows, %{}, fn {_, _, kind, n}, acc -> Map.update(acc, kind, n, &(&1 + n)) end)

      sum = fn pred -> rows |> Enum.filter(pred) |> Enum.map(&elem(&1, 3)) |> Enum.sum() end

      %{
        uuid: Ecto.UUID.load!(bin),
        today: sum.(fn {_, d, _, _} -> d == today end),
        week: sum.(fn {_, d, _, _} -> Date.compare(d, week) != :lt end),
        total: sum.(fn _ -> true end),
        kinds: kinds,
        last_day: rows |> Enum.map(&elem(&1, 1)) |> Enum.max(Date),
        score: Enum.reduce(kinds, 0, fn {k, n}, acc -> acc + n * Map.get(@weights, k, 1) end)
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end
end
