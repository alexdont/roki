defmodule Roki.AnimeRank do
  @moduledoc """
  The order anime are listed in when the question is "what is on".

  TMDB's popularity is a measure of how much a title is looked at now, over everything it ever was,
  so the evergreens always win: Doraemon, Detective Conan, Bleach and Maruko have an episode out
  in every season and are always among the most popular. They are not what anyone opening a
  season's list is looking for. They are not left out (they are airing, and someone may want
  Conan), but they go last. For the rest, a title's popularity is weighed by how recently it began
  (`weight/1`), and what premiered in the season being looked at counts in full: a new show with
  a fifth of Doraemon's popularity still comes first.
  """

  @doc """
  How much of its popularity a title keeps, by the age of the show in years (the year it began
  against the year being looked at): this year's and last year's in full, then falling away.
  """
  def weight(age) when age <= 1, do: 1.0
  def weight(age) when age <= 3, do: 0.5
  def weight(age) when age <= 6, do: 0.25
  def weight(age) when age <= 12, do: 0.1
  def weight(_age), do: 0.04

  # A show this many years old (and not premiering now) is an evergreen: it is in every season's
  # list, and goes after everything else in it.
  @evergreen_years 15

  @doc """
  `items` (each with `:id`, `:year`, `:popularity`) best first, the evergreens last. `year` is the
  year being looked at; `new` is the ids that premiered in the window and so count in full
  whatever their year.
  """
  def rank(items, year, new \\ MapSet.new()) do
    {evergreen, current} =
      Enum.split_with(items, &(not MapSet.member?(new, &1[:id]) and age(&1, year) >= @evergreen_years))

    by_score(current, year, new) ++ by_score(evergreen, year, new)
  end

  defp by_score(items, year, new) do
    items
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, i} -> {-score(item, year, new), i} end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "The popularity a title is ranked by."
  def score(item, year, new) do
    popularity = item[:popularity] || 0
    if MapSet.member?(new, item[:id]), do: popularity * 1.0, else: popularity * weight(age(item, year))
  end

  @doc """
  The age that counts: the year the show began, or — when it is known (`refine/3`) — the year its
  latest season began, whichever is later. Bleach began in 2004 but its season airing now began in
  2022; Doraemon has only ever had its first.
  """
  def age(item, year) do
    # A title whose year is not known is taken as middle-aged rather than as new or ancient.
    case max(began(item), item[:season_year] || 0) do
      0 -> 5
      since -> max(year - since, 0)
    end
  end

  defp began(%{year: y}) when is_binary(y) do
    case Integer.parse(y) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp began(%{year: y}) when is_integer(y), do: y
  defp began(_item), do: 0

  @doc """
  The year each of the most popular old shows among `items` last began a season (`:season_year`),
  asked of `latest_season_year` (an id → year or nil). Only the `limit` most popular of the shows
  that began four or more years before `year` are asked about — they are the ones a new season of
  an old show (Bleach, JoJo) would come from and the ones whose weight it changes.
  """
  def refine(items, year, latest_season_year, limit \\ 12) do
    asked =
      items
      |> Enum.filter(&(age(&1, year) >= 4))
      |> Enum.sort_by(&(-(&1[:popularity] || 0)))
      |> Enum.take(limit)
      |> MapSet.new(& &1[:id])

    Enum.map(items, fn item ->
      if MapSet.member?(asked, item[:id]),
        do: Map.put(item, :season_year, latest_season_year.(item[:id])),
        else: item
    end)
  end

  @doc """
  The year the latest season of a TMDB show began (nil when TMDB dates none), kept for half a
  day. Season 0 (specials) does not count. Runs in a laev scope that holds a TMDB key.
  """
  def latest_season_year(id) do
    case Roki.TTLCache.fetch({:anime_season_year, id}, 12 * 3600, fn ->
           case Laev.Tmdb.tv(id) do
             {:ok, details} -> {:ok, season_year(details)}
             _ -> {:error, :unknown}
           end
         end) do
      {:ok, year} -> year
      _ -> nil
    end
  end

  @doc false
  def season_year(%{"seasons" => seasons}) when is_list(seasons) do
    seasons
    |> Enum.filter(&((&1["season_number"] || 0) > 0))
    |> Enum.flat_map(fn
      %{"air_date" => <<year::binary-size(4), _::binary>>} ->
        case Integer.parse(year) do
          {n, ""} -> [n]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.max(fn -> nil end)
  end

  def season_year(_details), do: nil
end
