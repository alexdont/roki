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
    items = [
      a(1, 2026, 10.0),
      a(2, 2026, 10.0),
      %{id: 3, year: nil, popularity: 10.0},
      %{id: 4, popularity: nil, year: "2026"}
    ]

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

  defp seasons(list),
    do:
      for(
        {n, date, poster} <- list,
        do: %{n: n, air_date: date && Date.from_iso8601!(date), poster: poster}
      )

  defp jojo,
    do:
      seasons([
        {0, "2017-09-20", "/special.jpg"},
        {1, "2012-10-06", "/s1.jpg"},
        {5, "2022-01-08", "/s5.jpg"},
        {6, "2026-03-19", "/s6.jpg"}
      ])

  test "a show that is back with a later season is drawn with that season's poster" do
    items = [
      %{id: 1, year: "2012", popularity: 120.0, poster: "https://image.tmdb.org/t/p/w342/s1.jpg"}
    ]

    [item] = AnimeRank.refine(items, ~D[2026-12-31], fn 1 -> jojo() end)
    assert item.poster == "https://image.tmdb.org/t/p/w342/s6.jpg"
    assert item.season_year == 2026
  end

  test "the season that counts is the latest one begun by the end of the period looked at" do
    items = [%{id: 1, year: "2012", popularity: 120.0, poster: "old"}]

    # Looking at the winter of 2022: its season is the fifth, not the one that came later
    [item] = AnimeRank.refine(items, ~D[2022-03-31], fn 1 -> jojo() end)
    assert item.poster == "https://image.tmdb.org/t/p/w342/s5.jpg"
    assert item.season_year == 2022
  end

  test "a show with one season, or whose latest season is long past, keeps the show's poster" do
    one = [%{id: 2, year: "2005", popularity: 280.0, poster: "show"}]

    [item] =
      AnimeRank.refine(one, ~D[2026-12-31], fn 2 -> seasons([{1, "2005-04-22", "/s1.jpg"}]) end)

    assert item.poster == "show"

    old = [%{id: 3, year: "2004", popularity: 50.0, poster: "show"}]

    [item] =
      AnimeRank.refine(old, ~D[2026-12-31], fn 3 ->
        seasons([{1, "2004-10-05", "/a.jpg"}, {2, "2019-04-01", "/b.jpg"}])
      end)

    assert item.poster == "show"
    # but the age that counts is still its latest season's
    assert item.season_year == 2019
  end

  test "a season with no poster, an undated or special season, or a show not read, leaves the item as it was" do
    items = [
      %{id: 4, year: "2010", popularity: 10.0, poster: "show"},
      %{id: 5, year: "2011", popularity: 9.0, poster: "show2"}
    ]

    seasons_of = fn
      4 ->
        seasons([
          {1, "2010-01-01", "/a.jpg"},
          {2, "2026-04-01", nil},
          {0, "2026-05-01", "/special.jpg"},
          {3, nil, "/c.jpg"}
        ])

      5 ->
        []
    end

    [a, b] = AnimeRank.refine(items, ~D[2026-12-31], seasons_of)
    assert a.poster == "show"
    assert a.season_year == 2026
    assert b == Enum.at(items, 1)
  end

  test "new shows and shows begun this year are not asked about; the most popular old ones are, once each" do
    items = [
      %{id: 1, year: "2026", popularity: 90.0},
      %{id: 2, year: "2004", popularity: 196.0},
      %{id: 3, year: "2005", popularity: 278.0},
      %{id: 4, year: "1990", popularity: 5.0},
      %{id: 5, year: nil, popularity: 99.0}
    ]

    {:ok, asked} = Agent.start_link(fn -> [] end)

    AnimeRank.refine(
      items,
      ~D[2026-12-31],
      fn id ->
        Agent.update(asked, &[id | &1])
        []
      end,
      2
    )

    assert Agent.get(asked, & &1) |> Enum.sort() == [2, 3]
  end

  test "TMDB's season list is read into dates and posters" do
    details = %{
      "seasons" => [
        %{"season_number" => 0, "air_date" => "2017-09-20", "poster_path" => "/sp.jpg"},
        %{"season_number" => 1, "air_date" => "2004-10-05", "poster_path" => "/a.jpg"},
        %{"season_number" => 2, "air_date" => "", "poster_path" => nil}
      ]
    }

    assert [
             %{n: 0},
             %{n: 1, air_date: ~D[2004-10-05], poster: "/a.jpg"},
             %{n: 2, air_date: nil, poster: nil}
           ] =
             AnimeRank.parse_seasons(details)

    assert AnimeRank.parse_seasons(%{}) == []
  end
end
