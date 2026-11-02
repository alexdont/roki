defmodule Roki.AirDates do
  @moduledoc """
  When each season of a show was on: the day its first episode aired and the day of the last
  one out so far. What the back-date dialog shows, so a date can be picked by what you remember
  ("I had seen three seasons") rather than by calendar, and what "watched as it aired" dates each
  season with.

  Read from TMDB's season lists (`Roki.Watch.episodes/3`, kept for days), one list per season.
  """

  @doc """
  `[%{number:, first:, last:, episodes:, ended?:}]`, one per season out so far (specials left
  out), in order. `first` and `last` are `Date`s; `last` is the latest episode aired by today, and
  `ended?` says the season has no episode still to come.
  """
  def seasons(tv_id, uuid \\ nil) when is_integer(tv_id) do
    with {:ok, title} <- Roki.Watch.title("tv", tv_id, uuid) do
      title.seasons
      |> Enum.filter(&(&1.number > 0))
      |> Task.async_stream(&one(tv_id, &1.number, uuid), max_concurrency: 4, timeout: 30_000)
      |> Enum.flat_map(fn
        {:ok, %{} = season} -> [season]
        _ -> []
      end)
      |> Enum.sort_by(& &1.number)
    else
      _ -> []
    end
  end

  @doc """
  The seasons this account has watched any of, each with the day the last episode it watched came
  out — `[%{number:, date:}]`. Someone who watched as it aired watched an episode about the day it
  aired, so a season finished is dated by its last episode and one stopped in the middle by the
  last episode seen, not by episodes they have not got to. Episodes marked watched give the last
  one marked; a season only played (no marks) is taken to have been watched in order, as many
  episodes as were played. `[]` where nothing is on record.
  """
  def watched_seasons(tv_id, uuid) when is_integer(tv_id) do
    with {:ok, title} <- Roki.Watch.title("tv", tv_id, uuid) do
      marked = Roki.Watch.watched_pairs(uuid, title)

      played =
        case Roki.Laev.run(uuid, &Roki.Stats.season_episodes/0) do
          %{} = all -> Map.get(all, {"tv", tv_id}, %{})
          _ -> %{}
        end

      seasons =
        (Enum.map(marked, &elem(&1, 0)) ++ Map.keys(played))
        |> Enum.filter(&is_integer/1)
        |> Enum.uniq()
        |> Enum.sort()

      Enum.flat_map(seasons, fn season ->
        with {:ok, eps} <- Roki.Watch.episodes(tv_id, season, uuid),
             %Date{} = date <- last_watched_day(eps, season, marked, played[season]) do
          [%{number: season, date: date}]
        else
          _ -> []
        end
      end)
    else
      _ -> []
    end
  end

  defp last_watched_day(eps, season, marked, played) do
    dated =
      for %{number: n, air_date: d} <- eps,
          is_binary(d),
          {:ok, date} <- [Date.from_iso8601(d)],
          do: {n, date}

    seen = for {n, date} <- dated, MapSet.member?(marked, {season, n}), do: date

    cond do
      seen != [] ->
        Enum.max(seen, Date)

      is_map(played) and is_integer(played[:episodes]) and played[:episodes] > 0 and dated != [] ->
        dated
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.take(played.episodes)
        |> List.last()
        |> elem(1)

      true ->
        nil
    end
  end

  defp one(tv_id, number, uuid) do
    with {:ok, eps} <- Roki.Watch.episodes(tv_id, number, uuid) do
      dates =
        for %{air_date: d} <- eps, is_binary(d), {:ok, date} <- [Date.from_iso8601(d)], do: date

      out = Enum.filter(eps, & &1.aired?)

      case {Enum.sort(dates, Date), out} do
        {[first | _], [_ | _]} ->
          aired = Enum.filter(dates, &(Date.compare(&1, Date.utc_today()) != :gt))

          %{
            number: number,
            first: first,
            last: Enum.max(aired, Date),
            episodes: length(out),
            ended?: length(out) == length(eps)
          }

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end
end
