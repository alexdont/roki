defmodule Roki.GenreNameTest do
  use ExUnit.Case, async: true

  alias Roki.Genres

  test "a title's genre name leads to the slug its kind is browsed by" do
    assert Genres.slug_for_name("Science Fiction", :movies) == "scifi"
    assert Genres.slug_for_name("Sci-Fi & Fantasy", :shows) == "scifi"
    assert Genres.slug_for_name("Action & Adventure", :anime) == "action"
    assert Genres.slug_for_name("Horror", :shows) == "horror"
  end

  test "a genre the kind cannot be browsed by, or one that is not known, leads nowhere" do
    assert Genres.slug_for_name("Romance", :shows) == nil
    assert Genres.slug_for_name("Soap", :shows) == nil
    assert Genres.slug_for_name("TV Movie", :movies) == nil
  end
end
