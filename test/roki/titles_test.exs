defmodule Roki.TitlesTest do
  use Roki.DataCase, async: true

  alias Roki.Titles

  @film %{
    type: "movie",
    id: 10_331,
    title: "Easy A",
    year: "2010",
    date: "2010-09-10",
    poster_path: "/easyA.jpg",
    overview: "A rumour.",
    status: "Released",
    seasons: [],
    search: %{search: ["Easy A"], accept: ["Easy A"]}
  }

  test "a whole title is kept, and a film that is out is never read again" do
    assert Titles.get("movie", 10_331) == :none
    assert :ok = Titles.put(@film)
    assert {:ok, title, true} = Titles.get("movie", 10_331)
    assert title.title == "Easy A"
    assert title.search.accept == ["Easy A"]
    assert title.seasons == []
  end

  test "a running show is read again after two weeks" do
    show = %{@film | type: "tv", id: 1396, title: "Breaking Bad", status: "Returning Series", date: "2008-01-20"}
    Titles.put(show)
    assert {:ok, _, true} = Titles.get("tv", 1396)

    Roki.Repo.query!("update roki_titles set fetched_at = now() - interval '15 days' where type = 'tv' and id = 1396")
    assert {:ok, _, false} = Titles.get("tv", 1396)

    Titles.put(%{show | status: "Ended"})
    Roki.Repo.query!("update roki_titles set fetched_at = now() - interval '15 days' where type = 'tv' and id = 1396")
    assert {:ok, _, true} = Titles.get("tv", 1396)
  end

  test "a list leaves its cards behind without touching a whole title" do
    Titles.put(@film)

    Titles.remember([
      %{type: "movie", id: 10_331, title: "Easy A (other name)", poster: "https://image.tmdb.org/t/p/w500/other.jpg"},
      %{type: "tv", id: 1396, title: "Breaking Bad", poster: "https://image.tmdb.org/t/p/w342/bb.jpg", year: "2008"},
      %{type: "tv", id: 1, title: "", poster: nil},
      %{type: "person", id: 2, title: "Nobody"}
    ])

    assert %{title: "Easy A", poster: "https://image.tmdb.org/t/p/w342/easyA.jpg"} = Titles.card("movie", 10_331)
    assert %{title: "Breaking Bad", year: "2008", poster: "https://image.tmdb.org/t/p/w342/bb.jpg"} = Titles.card("tv", 1396)
    assert Titles.card("tv", 1) == nil
    assert Titles.card("person", 2) == nil
    assert map_size(Titles.cards([{"movie", 10_331}, {"tv", 1396}, {"tv", 99}])) == 2
  end

  test "pictures are named by the site's own address, everything else is left alone" do
    assert Roki.Images.local("https://image.tmdb.org/t/p/w342/abcDEF123.jpg") == "/img/w342/abcDEF123.jpg"
    assert Roki.Images.local("https://image.tmdb.org/t/p/w1280/x.png") == "/img/w1280/x.png"
    # One file per picture, whatever size is asked for.
    assert Roki.Images.key("https://image.tmdb.org/t/p/w342/abc.jpg") == Roki.Images.key("https://image.tmdb.org/t/p/w500/abc.jpg")
    assert Roki.Images.variant_for("https://image.tmdb.org/t/p/original/abc.jpg") == "original"
    assert Roki.Images.variant_for("https://cdn.myanimelist.net/images/anime/1/2.jpg") == "original"
    assert Roki.Images.local("https://image.tmdb.org/t/p/w342/../etc") == "https://image.tmdb.org/t/p/w342/../etc"
    assert Roki.Images.local("https://image.tmdb.org/t/p/w9/x.jpg") == "https://image.tmdb.org/t/p/w9/x.jpg"
    assert Roki.Images.local("https://cdn.myanimelist.net/images/anime/1234/56789l.jpg") == "/img/mal/anime/1234/56789l.jpg"
    assert Roki.Images.local("https://cdn.myanimelist.net/images/anime/../x.jpg") == "https://cdn.myanimelist.net/images/anime/../x.jpg"
    assert Roki.Images.local("/phoenix_kit/file/x/original/t") == "/phoenix_kit/file/x/original/t"
    assert Roki.Images.local(nil) == nil
    assert Roki.Images.ensure("w342/../x.jpg") == {:error, :bad_name}
    assert Roki.Images.ensure("huge/x.jpg") == {:error, :bad_name}
    assert Roki.Images.source_url("mal/anime/1/2.jpg") == "https://cdn.myanimelist.net/images/anime/1/2.jpg"
  end
end
