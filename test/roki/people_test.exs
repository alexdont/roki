defmodule Roki.PeopleTest do
  use ExUnit.Case, async: true

  alias Roki.People

  @body %{
    "id" => 6193,
    "name" => "Leonardo DiCaprio",
    "profile_path" => "/leo.jpg",
    "known_for_department" => "Acting",
    "combined_credits" => %{
      "cast" => [
        %{
          "media_type" => "movie",
          "id" => 27205,
          "title" => "Inception",
          "release_date" => "2010-07-15",
          "poster_path" => "/i.jpg",
          "character" => "Cobb",
          "vote_average" => 8.4,
          "popularity" => 90.0,
          "genre_ids" => [28]
        },
        %{
          "media_type" => "movie",
          "id" => 597,
          "title" => "Titanic",
          "release_date" => "1997-11-18",
          "poster_path" => "/t.jpg",
          "character" => "Jack",
          "vote_average" => 7.9,
          "popularity" => 80.0,
          "genre_ids" => [18]
        },
        # The same film twice (two roles): once.
        %{
          "media_type" => "movie",
          "id" => 597,
          "title" => "Titanic",
          "release_date" => "1997-11-18",
          "character" => "Jack (voice)",
          "genre_ids" => [18]
        },
        # A talk show appearance, and himself in a documentary: not acting.
        %{
          "media_type" => "tv",
          "id" => 1,
          "name" => "Late Night",
          "first_air_date" => "2015-01-01",
          "character" => "Self - Guest",
          "genre_ids" => [10767]
        },
        %{
          "media_type" => "movie",
          "id" => 2,
          "title" => "Before the Flood",
          "release_date" => "2016-10-21",
          "character" => "Himself",
          "genre_ids" => [99]
        },
        %{
          "media_type" => "movie",
          "id" => 3,
          "title" => "Some Doc",
          "release_date" => "2017-01-01",
          "character" => "Narrator (himself)",
          "genre_ids" => [99]
        },
        # A show he acted in, and a film with no date yet.
        %{
          "media_type" => "tv",
          "id" => 4,
          "name" => "Growing Pains",
          "first_air_date" => "1985-09-24",
          "character" => "Luke",
          "genre_ids" => [35]
        },
        %{
          "media_type" => "movie",
          "id" => 5,
          "title" => "Untitled",
          "release_date" => "",
          "character" => "Lead",
          "genre_ids" => []
        },
        %{"media_type" => "person", "id" => 6, "name" => "Odd"}
      ]
    }
  }

  test "the person and what they acted in, newest first, each title once" do
    assert %{id: 6193, name: "Leonardo DiCaprio", known_for: "Acting", cards: cards} =
             person = People.parse(@body)

    assert person.photo == "https://image.tmdb.org/t/p/w342/leo.jpg"

    assert Enum.map(cards, &{&1.type, &1.id}) == [
             {"movie", 27205},
             {"movie", 597},
             {"tv", 4},
             {"movie", 5}
           ]

    assert hd(cards) == %{
             type: "movie",
             id: 27205,
             title: "Inception",
             year: "2010",
             date: "2010-07-15",
             overview: nil,
             poster: "https://image.tmdb.org/t/p/w342/i.jpg",
             vote: 8.4,
             popularity: 90.0,
             character: "Cobb"
           }

    assert Enum.find(cards, &(&1.id == 4)).title == "Growing Pains"
  end

  test "an answer without a person is none" do
    assert People.parse(%{}) == nil
    assert People.parse(nil) == nil
  end
end
