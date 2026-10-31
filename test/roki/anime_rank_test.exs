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
    # the two evergreens are last, the older-but-newer-than-fifteen-years ones are not
  end

  test "evergreens go after everything else, but stay in the list" do
    items = [a(1, 2005, 278.0), a(2, 2026, 3.0), a(3, 1996, 151.0), a(4, 2020, 5.0)]
    ranked = AnimeRank.rank(items, 2026)
    assert Enum.map(ranked, & &1.id) == [2, 4, 1, 3]

    # …unless they premiered in the window
    assert hd(AnimeRank.rank(items, 2026, MapSet.new([1]))).id == 1
  end

  test "what premiered in the season counts in full, whatever its year" do
    items = [a(1, 2016, 100.0), a(2, 2016, 30.0), a(3, 2026, 20.0)]
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

  test "an old show with a recent season counts by that season, not by the year it began" do
    bleach = %{id: 1, year: "2004", popularity: 196.0, season_year: 2022}
    doraemon = %{id: 2, year: "2005", popularity: 278.0}
    conan = %{id: 3, year: "1996", popularity: 151.0, season_year: 1996}
    new = %{id: 4, year: "2026", popularity: 25.0}

    assert AnimeRank.age(bleach, 2026) == 4
    assert AnimeRank.age(doraemon, 2026) == 21
    # Bleach is nowhere near the evergreens at the end of the list
    ranked = AnimeRank.rank([doraemon, conan, bleach, new], 2026)
    assert Enum.map(ranked, & &1.id) == [1, 4, 2, 3]
  end

  test "refine asks only about the most popular old shows, and only once each" do
    items = [
      %{id: 1, year: "2004", popularity: 196.0},
      %{id: 2, year: "2005", popularity: 278.0},
      %{id: 3, year: "2026", popularity: 25.0},
      %{id: 4, year: "1990", popularity: 5.0}
    ]

    {:ok, asked} = Agent.start_link(fn -> [] end)

    refined =
      AnimeRank.refine(
        items,
        2026,
        fn id ->
          Agent.update(asked, &[id | &1])
          if id == 1, do: 2022
        end,
        2
      )

    assert Agent.get(asked, & &1) |> Enum.sort() == [1, 2]
    assert Enum.find(refined, &(&1.id == 1)).season_year == 2022
    refute Map.has_key?(Enum.find(refined, &(&1.id == 3)), :season_year)
    refute Map.has_key?(Enum.find(refined, &(&1.id == 4)), :season_year)
  end

  test "the latest season's year is read from TMDB's season list" do
    details = %{"seasons" => [%{"season_number" => 0, "air_date" => "2030-01-01"}, %{"season_number" => 1, "air_date" => "2004-10-05"}, %{"season_number" => 2, "air_date" => "2022-10-11"}, %{"season_number" => 3, "air_date" => ""}]}
    assert AnimeRank.season_year(details) == 2022
    assert AnimeRank.season_year(%{"seasons" => []}) == nil
    assert AnimeRank.season_year(%{}) == nil
  end
end
