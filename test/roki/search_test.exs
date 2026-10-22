defmodule Roki.SearchTest do
  use ExUnit.Case, async: true

  alias Roki.Search

  describe "spelling variants" do
    test "adds the other spelling, both ways" do
      assert Search.spelling_variants("in the gray") == ["in the gray", "in the grey"]
      assert Search.spelling_variants("In The Grey") == ["In The Grey", "in the gray"]

      assert Search.spelling_variants("the colour purple") == [
               "the colour purple",
               "the color purple"
             ]
    end

    test "a query with no variant is just itself" do
      assert Search.spelling_variants("alien") == ["alien"]
    end

    test "canonical treats both spellings as one" do
      assert Search.canonical("In the Grey") == Search.canonical("in the gray ")
    end
  end

  describe "year hint" do
    test "splits a trailing year" do
      assert Search.split_year("heat 1995") == {"heat", 1995}
      assert Search.split_year("blade runner 2049") == {"blade runner", 2049}
    end

    test "a bare year, or none, is not a hint" do
      assert Search.split_year("1995") == {"1995", nil}
      assert Search.split_year("alien") == {"alien", nil}
    end
  end

  describe "ranking" do
    defp t(title, year, pop),
      do: %{
        title: title,
        year: year,
        popularity: pop,
        type: "movie",
        id: :erlang.phash2({title, year})
      }

    test "exact title first, newest first, then popularity" do
      ranked =
        Search.rank_titles(
          [
            t("Heat Wave", "2001", 90.0),
            t("Heat", "1995", 10.0),
            t("Heat", "2022", 5.0),
            t("Night Heat", "1985", 50.0)
          ],
          "heat",
          nil
        )

      assert Enum.map(ranked, & &1.title) == ["Heat", "Heat", "Heat Wave", "Night Heat"]
      assert Enum.map(ranked, & &1.year) |> Enum.take(2) == ["2022", "1995"]
    end

    test "a year hint floats the year, then its neighbours" do
      ranked =
        Search.rank_titles(
          [
            t("Heat", "2022", 5.0),
            t("Heat", "1996", 4.0),
            t("Heat", "1995", 3.0),
            t("Heat", "1980", 9.0)
          ],
          "heat",
          1995
        )

      assert Enum.map(ranked, & &1.year) == ["1995", "1996", "2022", "1980"]
    end

    test "matches across spellings" do
      ranked =
        Search.rank_titles(
          [t("Gray Man", "2022", 1.0), t("The Grey", "2011", 1.0)],
          "the gray",
          nil
        )

      assert hd(ranked).title == "The Grey"
    end
  end

  test "queries are trimmed, collapsed and capped" do
    assert Search.clean("  heat    1995 ") == "heat 1995"
    assert String.length(Search.clean(String.duplicate("a", 500))) == 120
    assert Search.clean(nil) == ""
  end

  test "an empty query is not a TMDB request" do
    assert {:ok, [], false, [], seen} = Search.search({:ip, "t"}, nil, "   ")
    assert MapSet.size(seen) == 0
  end
end
