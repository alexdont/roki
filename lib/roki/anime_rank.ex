defmodule Roki.AnimeRank do
  @moduledoc """
  The order anime are listed in when the question is "what is on".

  TMDB's popularity is a measure of how much a title is looked at now, over everything it ever was,
  so the evergreens always win: Doraemon, Detective Conan, Bleach and Maruko have an episode out
  in every season and are always among the most popular. They are not what anyone opening a
  season's list is looking for. So a title's popularity is weighed by how recently it began
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

  @doc """
  `items` (each with `:id`, `:year`, `:popularity`) best first. `year` is the year being looked at;
  `new` is the ids that premiered in the window and so count in full whatever their year.
  """
  def rank(items, year, new \\ MapSet.new()) do
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

  # A title whose year is not known is taken as middle-aged rather than as new or ancient.
  defp age(%{year: y}, year) when is_binary(y) do
    case Integer.parse(y) do
      {n, _} -> max(year - n, 0)
      :error -> 5
    end
  end

  defp age(%{year: y}, year) when is_integer(y), do: max(year - y, 0)
  defp age(_item, _year), do: 5
end
