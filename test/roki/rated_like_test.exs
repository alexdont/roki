defmodule Roki.RatedLikeTest do
  use Roki.DataCase, async: true

  alias Roki.Profile

  test "the shelf of each score: newest first, six at most, this title left out, with cards" do
    uuid = Ecto.UUID.generate()

    Roki.Titles.remember([
      %{type: "movie", id: 1, title: "Heat", year: "1995", poster: "/heat.jpg"},
      %{type: "movie", id: 2, title: "Ronin", year: "1998"}
    ])

    # Rated on the site, one after the other: 1 then 2 then 3 … all 8s but the last.
    for id <- 1..7, do: Profile.note_rating(uuid, {"movie", id}, 8.0)
    Profile.note_rating(uuid, {"movie", 8}, 8.5)
    Profile.note_rating(uuid, {"tv", 9}, 8.0)

    shelf = Profile.rated_like(uuid, "movie", 7)
    assert Map.keys(shelf) |> Enum.sort() == ["8", "8.5"]
    # Newest first (7 is the one being rated, so it is left out), six at most.
    for id <- 10..12, do: Profile.note_rating(uuid, {"movie", id}, 8.0)
    shelf = Profile.rated_like(uuid, "movie", 7)
    assert Enum.map(shelf["8"], & &1.id) == [12, 11, 10, 6, 5, 4]
    assert [%{id: 8, title: nil, poster: nil}] = shelf["8.5"]
    # A show is not on a film's shelf.
    refute Enum.any?(shelf["8"], &(&1.type == "tv"))

    # Rating one again puts it first.
    Profile.note_rating(uuid, {"movie", 1}, 8.0)

    [%{id: 1, title: "Heat", year: "1995", poster: poster} | _] =
      Profile.rated_like(uuid, "movie")["8"]

    assert poster =~ "/heat.jpg"

    # (Six is six: 4 fell off the end.)
    assert Enum.map(Profile.rated_like(uuid, "movie")["8"], & &1.id) == [1, 12, 11, 10, 7, 6]
    assert Enum.find(Profile.rated_like(uuid, "movie", 10)["8"], &(&1.id == 2)) == nil

    assert Profile.rated_like(uuid, "movie", nil, 20)["8"]
           |> Enum.find(&(&1.id == 2))
           |> Map.get(:title) == "Ronin"
  end

  test "score keys are the slider's" do
    assert Profile.score_key(8) == "8"
    assert Profile.score_key(8.0) == "8"
    assert Profile.score_key(8.5) == "8.5"
    assert Profile.score_key(10.0) == "10"
  end
end
