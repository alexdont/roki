defmodule Roki.ListsTest do
  use ExUnit.Case, async: true

  alias Roki.Lists

  test "every curated list has a unique, url-safe slug that finds it again" do
    summaries = Lists.summaries()
    slugs = Enum.map(summaries, & &1.slug)

    assert length(summaries) == length(Laev.Franchises.all())
    assert slugs == Enum.uniq(slugs)
    assert Enum.all?(slugs, &Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, &1))

    for s <- summaries do
      assert {:ok, f} = Lists.find(s.slug)
      assert f.name == s.name
    end
  end

  test "biggest lists come first" do
    counts = Enum.map(Lists.summaries(), & &1.count)
    assert counts == Enum.sort(counts, :desc)
  end

  test "unknown and malformed slugs are just not found" do
    assert Lists.find("no-such-list") == :error
    assert Lists.find("collection-abc") == :error
    assert Lists.find("") == :error
  end

  test "summaries carry no progress until a user is connected" do
    assert Enum.all?(Lists.with_progress(nil, Lists.summaries()), &(&1.watched == nil))
  end

  test "an entry becomes a title from the file alone, with a season in its name" do
    entry = %{
      type: "tv",
      tmdb_id: 1,
      season: 2,
      title: "Some Show",
      date: "2014-09-23",
      rename: nil
    }

    item = Lists.base_item(entry)
    assert item.title == "Some Show · Season 2"
    assert item.year == "2014"
    assert item.poster == nil
  end

  test "TMDB's card fills in the poster and year, the curated rename wins" do
    entry = %{
      type: "movie",
      tmdb_id: 7,
      season: nil,
      title: "Nausicaa",
      date: "1984-03-11",
      rename: "Nausicaä of the Valley of the Wind"
    }

    cards = %{
      {"movie", 7} => %{
        "title" => "Kaze no Tani no Naushika",
        "poster_path" => "/p.jpg",
        "release_date" => "1984-03-11",
        "vote_average" => 8.0
      }
    }

    item = Lists.item(entry, cards)
    assert item.title == "Nausicaä of the Valley of the Wind"
    assert item.poster =~ "/w342/p.jpg"
    assert item.vote == 8.0
  end
end
