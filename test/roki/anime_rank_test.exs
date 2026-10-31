defmodule Roki.AnimeRankTest do
  use ExUnit.Case, async: true

  alias Roki.AnimeRank

  defp a(id, year, pop), do: %{id: id, year: to_string(year), popularity: pop, title: "T#{id}"}

  test "an evergreen no longer beats what is current" do
    items = [
      a(1, 2005, 278.0),
      a(2, 1996, 151.0),
      a(3, 2026, 36.0),
      a(4, 2026, 25.0),
      a(5, 2023, 111.0)
    ]

    assert Enum.map(AnimeRank.rank(items, 2026), & &1.id) == [5, 3, 4, 1, 2]
  end

  test "what premiered in the season counts in full, whatever its year" do
    items = [a(1, 2012, 100.0), a(2, 2012, 30.0), a(3, 2026, 20.0)]
    assert Enum.map(AnimeRank.rank(items, 2026), & &1.id) == [3, 1, 2]
    assert Enum.map(AnimeRank.rank(items, 2026, MapSet.new([2])), & &1.id) == [2, 3, 1]
  end

  test "a tie keeps the order it came in; unknown years are middle-aged; nothing is lost" do
    items = [a(1, 2026, 10.0), a(2, 2026, 10.0), %{id: 3, year: nil, popularity: 10.0}, %{id: 4, popularity: nil, year: "2026"}]
    ranked = AnimeRank.rank(items, 2026)
    assert Enum.map(ranked, & &1.id) == [1, 2, 3, 4]
    assert length(ranked) == 4
  end

  test "the weight falls with the age of the show" do
    weights = for age <- [0, 1, 3, 6, 12, 40], do: AnimeRank.weight(age)
    assert weights == Enum.sort(weights, :desc)
    assert hd(weights) == 1.0
  end
end
