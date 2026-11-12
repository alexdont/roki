defmodule Roki.SearchTest do
  use ExUnit.Case, async: true

  alias Roki.Search

  # The rules — spelling variants, the year hint, the ranking — are laev's (`Laev.Search`, tested
  # there); what is checked here is that the site calls them with its own shapes.
  test "the cache key is laev's canonical spelling" do
    assert Search.canonical("In the Grey") == Laev.Search.canonical("in the gray ")
  end

  test "laev's ranking takes the site's result maps (string years)" do
    t = fn title, year, pop ->
      %{
        title: title,
        year: year,
        popularity: pop,
        type: "movie",
        id: :erlang.phash2({title, year})
      }
    end

    ranked =
      Laev.Search.rank(
        [t.("Heat Wave", "2001", 90.0), t.("Heat", "1995", 10.0), t.("Heat", "2022", 5.0)],
        "heat",
        1995
      )

    assert Enum.map(ranked, &{&1.title, &1.year}) == [
             {"Heat", "1995"},
             {"Heat", "2022"},
             {"Heat Wave", "2001"}
           ]
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
