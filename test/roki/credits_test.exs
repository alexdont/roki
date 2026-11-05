defmodule Roki.CreditsTest do
  use ExUnit.Case, async: true

  alias Roki.Credits

  @body %{
    "cast" =>
      [
        %{"id" => 7, "name" => "A Actor", "character" => "Hero", "profile_path" => "/a.jpg"},
        %{"name" => "B Actor", "character" => "", "profile_path" => nil}
      ] ++
        for(n <- 1..30, do: %{"name" => "Extra #{n}", "character" => "x", "profile_path" => nil}),
    "crew" => [
      %{"name" => "D Director", "job" => "Director"},
      %{"name" => "D Director", "job" => "Director"},
      %{"name" => "W Writer", "job" => "Screenplay"},
      %{"name" => "Cam Era", "job" => "Director of Photography"},
      %{"name" => "Comp Oser", "job" => "Original Music Composer"}
    ]
  }

  test "the cast is cut to a row's worth, with a face where TMDB has one" do
    %{cast: [first, second | _] = cast} = Credits.parse(@body)
    assert length(cast) == 18

    assert first == %{
             id: 7,
             name: "A Actor",
             character: "Hero",
             photo: "https://image.tmdb.org/t/p/w185/a.jpg"
           }

    assert second.photo == nil
    # An empty character is no character.
    assert second.character == nil
  end

  test "directors are the Director credits only, each once; the composer is kept too" do
    assert %{directors: ["D Director"], writers: ["W Writer"], composers: ["Comp Oser"]} =
             Credits.parse(@body)
  end

  test "an answer with nothing in it, or none, is empty" do
    assert Credits.parse(%{}) == %{cast: [], directors: [], writers: [], composers: []}
    assert Credits.parse(nil) == Credits.empty()
  end
end
