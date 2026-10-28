defmodule Roki.Calendar do
  @moduledoc """
  A release calendar for a user's Saved list — laev's calendar, made to run on a
  server: when episodes of the shows and anime they have saved air, and when
  saved films reach theaters and digital.

  Sources, as in laev: **anime** — AniList's airing schedule; **TV** — TMDB's
  latest season, whose announced episodes carry air dates; **films** — TMDB release
  dates (earliest theatrical and digital).

  Laev's own `Laev.Calendar` keeps a seven-day look-back in the machine's temp
  directory. This keeps each title's whole schedule — everything the sources
  return, past and future — in `Roki.TTLCache` for six hours, shared between users
  (two people who saved the same show cost one lookup), so the page can show any
  month. A lookup that fails is never cached.

  Fetching spends from a per-client budget (only for titles not already cached) —
  see `Roki.RateLimit`.
  """

  alias Roki.{RateLimit, TTLCache}

  @ttl 6 * 3600
  # A title whose lookup failed is left alone this long, so one broken show costs a
  # request every ten minutes rather than one per page view.
  @failure_ttl 10 * 60
  @client_limit 3
  @global_limit 20
  @window 60_000

  @type event :: %{
          date: Date.t(),
          kind: :episode | :digital | :theatrical,
          label: String.t(),
          type: String.t(),
          id: integer(),
          title: String.t(),
          season: integer() | nil,
          episode: integer() | nil,
          anime: boolean()
        }

  @doc """
  `{:ok, %{events: [...], waiting: [...], saved: %{{type, id} => entry}}}` for the
  user's Saved list, or `{:error, reason}`. `events` are dated and sorted;
  `waiting` have no date yet (a season announced, a digital release not scheduled).
  """
  def load(client, uuid) do
    saved =
      Roki.Laev.run(uuid, fn ->
        Laev.Watchlist.all() |> Enum.reject(&(&1["type"] in ["franchise", "collection"]))
      end)

    entries = Enum.filter(saved, &(&1["type"] in ["movie", "tv"] and is_integer(&1["tmdb_id"])))

    with :ok <- budget(client, entries) do
      all =
        Roki.Laev.public(uuid, fn ->
          entries
          |> Laev.Scope.async_stream(&entry_events/1,
            max_concurrency: 4,
            timeout: 25_000,
            on_timeout: :kill_task
          )
          |> Enum.flat_map(fn
            {:ok, events} -> events
            _ -> []
          end)
        end)

      {waiting, dated} = Enum.split_with(all, &is_nil(&1.date))

      {:ok,
       %{
         events: Enum.sort_by(dated, &{Date.to_gregorian_days(&1.date), &1.title}),
         waiting: Enum.sort_by(waiting, & &1.title),
         saved:
           Map.new(
             saved,
             &{{&1["type"], &1["tmdb_id"]}, %{title: &1["title"], poster: &1["poster"]}}
           )
       }}
    end
  end

  @doc """
  The events of any list of titles, not only the Saved list: `entries` are maps with `"type"`,
  `"tmdb_id"` and `"title"`, as laev's saved entries are. `{:ok, events}` (dated, sorted) or
  `{:error, reason}` when the lookup budget for `client` is spent. Shares `load/2`'s cache, so a
  show someone saved and someone else follows is read once.
  """
  def events_for(client, uuid, entries) do
    entries = Enum.filter(entries, &(&1["type"] in ["movie", "tv"] and is_integer(&1["tmdb_id"])))

    with :ok <- budget(client, entries) do
      all =
        Roki.Laev.public(uuid, fn ->
          entries
          |> Laev.Scope.async_stream(&entry_events/1,
            max_concurrency: 4,
            timeout: 25_000,
            on_timeout: :kill_task
          )
          |> Enum.flat_map(fn
            {:ok, events} -> events
            _ -> []
          end)
        end)

      {:ok,
       all
       |> Enum.reject(&is_nil(&1.date))
       |> Enum.sort_by(&{Date.to_gregorian_days(&1.date), &1.title})}
    end
  end

  # Only titles that would reach a source count against the budget.
  defp budget(client, entries) do
    missing =
      Enum.count(
        entries,
        &(not TTLCache.cached?(key(&1)) and not TTLCache.cached?(failed_key(&1)))
      )

    if missing == 0 do
      :ok
    else
      with :ok <- RateLimit.check(:calendar, client, @client_limit, @window) do
        RateLimit.check(:calendar_global, :all, @global_limit, @window)
      end
    end
  end

  defp key(entry), do: {:calendar, entry["type"], entry["tmdb_id"]}
  defp failed_key(entry), do: {:calendar_failed, entry["type"], entry["tmdb_id"]}

  defp entry_events(entry) do
    if TTLCache.cached?(failed_key(entry)) do
      []
    else
      case TTLCache.fetch(key(entry), @ttl, fn -> fetch(entry) end) do
        {:ok, events} ->
          events

        _ ->
          TTLCache.fetch(failed_key(entry), @failure_ttl, fn -> {:ok, true} end)
          []
      end
    end
  rescue
    _ -> []
  end

  # ── what is coming, for the home page ──────────────────────────────

  @doc """
  The next few days: `{just_dropped, upcoming}` — yesterday's events, and the ones
  from today to a week out, each with `days` until it (0 = today).
  """
  def pulse(events, today \\ Date.utc_today(), ahead \\ 7) do
    yesterday = Date.add(today, -1)
    limit = Date.add(today, ahead)

    dropped = Enum.filter(events, &(&1.date == yesterday))

    upcoming =
      events
      |> Enum.filter(
        &(Date.compare(&1.date, today) != :lt and Date.compare(&1.date, limit) != :gt)
      )
      |> Enum.map(&Map.put(&1, :days, Date.diff(&1.date, today)))

    {dropped, upcoming}
  end

  @doc "\"today\", \"tomorrow\", \"in 3 days\"."
  def relative(0), do: "today"
  def relative(1), do: "tomorrow"
  def relative(n) when n > 1, do: "in #{n} days"
  def relative(-1), do: "yesterday"
  def relative(n), do: "#{-n} days ago"

  # ── sources (ported from laev, which keeps them private) ───────────

  defp fetch(%{"type" => "movie"} = entry) do
    with {:ok, %{"results" => results}} <- Laev.Tmdb.release_dates(entry["tmdb_id"]) do
      theatrical = earliest_release(results, 3)
      digital = earliest_release(results, 4)

      dated =
        for {kind, date} <- [theatrical: theatrical, digital: digital], date != nil do
          event(entry, parse_date(date), kind, "#{entry["title"]} — #{kind} release")
        end

      # In theaters with no digital date yet: the wait for a proper release.
      waiting =
        if digital == nil and theatrical != nil and
             theatrical <= Date.to_iso8601(Date.utc_today()) do
          [
            event(
              entry,
              nil,
              :digital,
              "#{entry["title"]} — in theaters since #{theatrical}, digital TBA"
            )
          ]
        else
          []
        end

      {:ok, dated ++ waiting}
    end
  end

  defp fetch(%{"type" => "tv"} = entry) do
    with {:ok, details} <- Laev.Tmdb.tv(entry["tmdb_id"]) do
      if anime?(details), do: anime_events(entry), else: {:ok, tv_events(entry, details)}
    end
  end

  defp fetch(_entry), do: {:ok, []}

  defp tv_events(_entry, %{"status" => status}) when status in ["Ended", "Canceled"], do: []

  defp tv_events(entry, details) do
    seasons =
      (details["seasons"] || [])
      |> Enum.filter(&(&1["season_number"] > 0))
      |> Enum.map(& &1["season_number"])
      |> Enum.sort(:desc)

    # TMDB often lists an announced placeholder season above the one actually
    # airing — use the first of the last two that has real air dates.
    dated =
      seasons
      |> Enum.take(2)
      |> Enum.find_value([], fn season ->
        case season_events(entry, season) do
          [] -> nil
          events -> events
        end
      end)

    case {dated, seasons} do
      {[], [latest | _]} ->
        [
          event(entry, nil, :episode, "#{entry["title"]} S#{pad(latest)} — announced, dates TBA",
            season: latest
          )
        ]

      {dated, _} ->
        dated
    end
  end

  defp season_events(entry, season) do
    case Laev.Tmdb.season(entry["tmdb_id"], season) do
      {:ok, %{"episodes" => episodes}} ->
        for e <- episodes,
            e["air_date"] not in [nil, ""],
            date = parse_date(e["air_date"]),
            date != nil do
          event(
            entry,
            date,
            :episode,
            "#{entry["title"]} S#{pad(season)}E#{pad(e["episode_number"])}",
            season: season,
            episode: e["episode_number"]
          )
        end

      _ ->
        []
    end
  end

  @anime_query """
  query($s:String){Media(search:$s,type:ANIME,status_in:[RELEASING,NOT_YET_RELEASED]){
    title{romaji}
    airingSchedule(notYetAired:true,perPage:12){nodes{episode airingAt}}}}
  """

  defp anime_events(entry) do
    case Req.post("https://graphql.anilist.co",
           json: %{query: @anime_query, variables: %{s: entry["title"]}},
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"Media" => %{"airingSchedule" => sched} = media}}}} ->
        romaji = get_in(media, ["title", "romaji"]) || entry["title"]

        {:ok,
         for %{"episode" => n, "airingAt" => at} <- sched["nodes"] || [] do
           date = at |> DateTime.from_unix!() |> DateTime.to_date()
           event(entry, date, :episode, "#{romaji} E#{pad(n)}", episode: n, anime: true)
         end}

      # AniList answers 404 for a title it has nothing airing for: that is "no schedule", not a failure.
      {:ok, %{status: status}} when status in [200, 404] ->
        {:ok, []}

      _ ->
        {:error, :anilist}
    end
  end

  defp event(entry, date, kind, label, extra \\ []) do
    %{
      date: date,
      kind: kind,
      label: label,
      type: entry["type"],
      id: entry["tmdb_id"],
      title: entry["title"] || "Untitled",
      season: extra[:season],
      episode: extra[:episode],
      anime: extra[:anime] == true
    }
  end

  defp earliest_release(results, type_id) do
    results
    |> Enum.flat_map(&(&1["release_dates"] || []))
    |> Enum.filter(&(&1["type"] == type_id and is_binary(&1["release_date"])))
    |> Enum.map(&String.slice(&1["release_date"], 0, 10))
    |> Enum.min(fn -> nil end)
  end

  defp anime?(%{"original_language" => "ja", "genres" => genres}) when is_list(genres),
    do: Enum.any?(genres, &(&1["id"] == 16))

  defp anime?(_), do: false

  defp parse_date(nil), do: nil

  defp parse_date(string) do
    case Date.from_iso8601(string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")
end
