defmodule Roki.ReviewsTileTest do
  use ExUnit.Case, async: true

  alias Roki.Reviews

  @ctx %{ids: %{"imdb" => "tt0133093", "mal" => nil, "tmdb" => 603}, type: "movie", id: 603}

  defp tile(source, value, extra \\ %{}),
    do: Reviews.tile(Map.merge(%{"source" => source, "value" => value, "votes" => 1000}, extra), @ctx)

  test "a score is set against what is typical on its own service" do
    imdb = tile("imdb", 8.7, %{"score" => 87})
    assert %{verdict: :great, typical: 66, delta: 21, norm: 87.0} = imdb

    # the same raw look-alike numbers mean different things on different scales
    assert tile("imdb", 6.6, %{"score" => 66}).verdict == :typical
    assert tile("tomatoes", 60, %{"score" => 60}).verdict == :typical
    assert tile("tomatoes", 83, %{"score" => 83}).verdict == :great
    assert tile("imdb", 7.2, %{"score" => 72}).verdict == :good
    assert tile("imdb", 5.8, %{"score" => 58}).verdict == :below
    assert tile("imdb", 4.0, %{"score" => 40}).verdict == :poor
  end

  test "a score MDBList did not convert is put on the same 0-100 scale from its own" do
    assert %{norm: 75.0, verdict: :good} = tile("rogerebert", 3.0, %{"score" => nil, "url" => "the-matrix-1999"})
    assert %{norm: 84.0} = tile("letterboxd", 4.2, %{"score" => nil})
  end

  test "each tile links to the title on its service" do
    assert tile("imdb", 8.7, %{"url" => 182}).url == "https://www.imdb.com/title/tt0133093/"
    assert tile("tomatoes", 83, %{"url" => "/m/matrix"}).url == "https://www.rottentomatoes.com/m/matrix"
    assert tile("popcorn", 85, %{"url" => "/m/matrix"}).url == "https://www.rottentomatoes.com/m/matrix"
    assert tile("metacritic", 73, %{"url" => "/the-matrix"}).url == "https://www.metacritic.com/movie/the-matrix/"
    assert tile("letterboxd", 4.2, %{"url" => "/film/the-matrix/"}).url == "https://letterboxd.com/film/the-matrix/"
    assert tile("rogerebert", 3.0, %{"url" => "the-matrix-1999"}).url == "https://www.rogerebert.com/reviews/the-matrix-1999"
    assert tile("tmdb", 82).url == "https://www.themoviedb.org/movie/603"
    assert tile("trakt", 87).url == "https://trakt.tv/search/imdb/tt0133093"
  end

  test "a show's links say tv, and MyAnimeList needs its id" do
    show = %{ids: %{"imdb" => "tt1", "mal" => 52_991}, type: "tv", id: 209_867}
    assert Reviews.tile(%{"source" => "tmdb", "value" => 88}, show).url == "https://www.themoviedb.org/tv/209867"
    assert Reviews.tile(%{"source" => "metacritic", "value" => 80, "url" => "/frieren"}, show).url == "https://www.metacritic.com/tv/frieren/"
    assert Reviews.tile(%{"source" => "myanimelist", "value" => 9.2}, show).url == "https://myanimelist.net/anime/52991"
    assert Reviews.tile(%{"source" => "myanimelist", "value" => 9.2}, %{show | ids: %{"mal" => nil}}).url == nil
  end

  test "what the service has no number for is not a tile" do
    assert Reviews.tile(%{"source" => "myanimelist", "value" => nil}, @ctx) == nil
    assert Reviews.tile(%{"source" => "somewhere", "value" => 5}, @ctx) == nil
  end
end
