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
  Looks at the seasons of the shows among `items` that began before `ref_date`'s year (the most
  popular `limit` of them), asked of `seasons_of` (an id → `[%{n:, air_date:, poster:}]`), and
  sets two things on each:

    * `:season_year` — the year its latest season (by `ref_date`) began, which `age/2` counts by:
      Bleach began in 2004, its season airing now in 2022.
    * `:poster` — that season's own poster, when the show has several seasons and the latest of
      them began within three years of `ref_date`. TMDB's poster for a show is its first season's,
      so a show that is back with a later season (JoJo's is on its seventh part) would otherwise
      be drawn as it was years ago. A show with one season, or whose latest season is long past,
      keeps the show's poster.

  `ref_date` is the end of the period being looked at (today, for what is on now). The seasons of
  the shows are asked for a few at a time, which is what `uuid` is for: each asks in its own scope.
  """
  def refine(items, ref_date, seasons_of, limit \\ 40) do
    year = ref_date.year

    asked =
      items
      |> Enum.filter(&(began(&1) in 1..(year - 1)//1))
      |> Enum.sort_by(&(-(&1[:popularity] || 0)))
      |> Enum.take(limit)

    found =
      asked
      |> Task.async_stream(&{&1[:id], seasons_of.(&1[:id])},
        max_concurrency: 8,
        timeout: 25_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {id, [_ | _] = seasons}}, acc -> Map.put(acc, id, seasons)
        _, acc -> acc
      end)

    Enum.map(items, fn item ->
      case Map.get(found, item[:id]) do
        nil -> item
        seasons -> apply_seasons(item, seasons, ref_date)
      end
    end)
  end

  defp apply_seasons(item, seasons, ref_date) do
    dated =
      seasons
      |> Enum.filter(&(&1.n > 0 and match?(%Date{}, &1.air_date) and Date.compare(&1.air_date, ref_date) != :gt))
      |> Enum.sort_by(& &1.air_date, Date)

    case List.last(dated) do
      nil ->
        item

      latest ->
        item = Map.put(item, :season_year, latest.air_date.year)

        if length(dated) >= 2 and is_binary(latest.poster) and
             Date.diff(ref_date, latest.air_date) <= 3 * 366,
           do: Map.put(item, :poster, Laev.Tmdb.poster_url(latest.poster, "w342")),
           else: item
    end
  end

  @doc """
  A show's seasons — `[%{n:, air_date:, poster:}]`, `[]` when they cannot be read — from the store
  `Roki.SeasonPosters` keeps. Called from several tasks at once, none of which has a scope: it asks
  in `uuid`'s (or the site's) own.
  """
  def seasons_of(id, uuid), do: Roki.SeasonPosters.seasons(id, uuid)

  @doc false
  def parse_seasons(%{"seasons" => seasons}) when is_list(seasons) do
    for s <- seasons, is_integer(s["season_number"]) do
      air_date =
        with date when is_binary(date) <- s["air_date"],
             {:ok, d} <- Date.from_iso8601(date),
             do: d,
             else: (_ -> nil)

      %{n: s["season_number"], air_date: air_date, poster: s["poster_path"]}
    end
  end

  def parse_seasons(_details), do: []
end
