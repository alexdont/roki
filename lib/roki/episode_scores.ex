defmodule Roki.EpisodeScores do
  @moduledoc """
  Every episode's score, season by season, for the seriesgraph-like grid in a show's Reviews sheet
  (ALEX-160): TMDB's own average for each episode (`vote_average`, with `vote_count` so a score
  three people gave can be told from one three thousand gave). Specials (season 0) are left out,
  and so is anything not aired yet.

  One TMDB read per season (four at a time), kept in `Roki.Kept` (`ep_scores`) for three days and
  in `Roki.TTLCache` for half a day, so the sheet opened again — by anyone — asks nobody. A show
  with more than #{40} seasons is cut at its newest #{40}.
  """

  alias Roki.{Kept, TTLCache}

  @kept_s 3 * 24 * 3600
  @cache_s 12 * 3600
  @max_seasons 40

  @typedoc "One season: `%{number, episodes: [%{number, name, score, votes, air_date}], average}`."
  @type season :: map()

  @doc """
  `{:ok, [season]}` oldest season first (`score` nil for an episode nobody has rated yet,
  `average` over the rated ones, nil when none), or `{:error, reason}`.
  """
  def for_show(tv_id, uuid \\ nil) when is_integer(tv_id) do
    TTLCache.fetch({:ep_scores, tv_id}, @cache_s, fn ->
      Kept.fetch("ep_scores", Integer.to_string(tv_id), @kept_s, fn -> read(tv_id, uuid) end)
    end)
    |> case do
      {:ok, seasons} when is_list(seasons) -> {:ok, Enum.map(seasons, &shape/1)}
      {:ok, _} -> {:error, :bad_data}
      other -> other
    end
  end

  defp read(tv_id, uuid) do
    with {:ok, title} <- Roki.Watch.title("tv", tv_id, uuid) do
      numbers =
        (title[:seasons] || [])
        |> Enum.map(&(&1[:number] || &1["number"]))
        |> Enum.filter(&(is_integer(&1) and &1 > 0))
        |> Enum.sort()
        |> Enum.take(-@max_seasons)

      today = Date.to_iso8601(Date.utc_today())

      seasons =
        numbers
        |> Task.async_stream(&{&1, season(tv_id, &1, uuid, today)},
          max_concurrency: 4,
          timeout: 20_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, {n, {:ok, eps}}} when eps != [] -> [%{"number" => n, "episodes" => eps}]
          _ -> []
        end)

      # Kept as JSON (string keys); `shape/1` makes the atoms on the way out.
      if seasons == [] and numbers != [], do: {:error, :no_episodes}, else: {:ok, seasons}
    end
  end

  @doc false
  def season(tv_id, n, uuid, today) do
    Roki.Laev.public(uuid, fn ->
      with {:ok, %{"episodes" => eps}} <- Laev.Tmdb.season(tv_id, n) do
        {:ok,
         for e <- eps,
             is_binary(e["air_date"]) and e["air_date"] != "" and e["air_date"] <= today do
           votes = e["vote_count"] || 0

           %{
             "number" => e["episode_number"],
             "name" => e["name"],
             "score" => if(votes > 0 and is_number(e["vote_average"]), do: e["vote_average"]),
             "votes" => votes,
             "air_date" => e["air_date"]
           }
         end}
      end
    end)
  end

  # Kept rows come back with atom keys where the atom exists (`Roki.Kept`) and string keys where
  # it does not, so a field is read under either.
  defp f(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  @doc false
  def shape(season) when is_map(season) do
    eps =
      for e <- f(season, "episodes") || [] do
        %{
          number: f(e, "number"),
          name: f(e, "name"),
          score: f(e, "score"),
          votes: f(e, "votes") || 0,
          air_date: f(e, "air_date")
        }
      end

    rated = for %{score: s} when is_number(s) <- eps, do: s
    average = if rated != [], do: Float.round(Enum.sum(rated) / length(rated), 1)

    %{number: f(season, "number"), episodes: eps, average: average}
  end
end
