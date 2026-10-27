defmodule Roki.GenresTest do
  use Roki.DataCase, async: true

  alias Roki.Genres

  test "a genre means each kind's own ids, and a kind without the genre is not offered it" do
    assert Genres.ids("action", :movies) == [28]
    assert Genres.ids("action", :shows) == [10759]
    assert Genres.ids("scifi", "movie") == [878]
    assert Genres.ids("scifi", "tv") == [10765]
    assert Genres.ids("horror", :shows) == []

    assert {"horror", "Horror"} in Genres.options(:movies)
    refute {"horror", "Horror"} in Genres.options(:shows)
    refute {"horror", "Horror"} in Genres.options(:anime)
    assert {"kids", "Kids"} in Genres.options(:shows)
    refute {"kids", "Kids"} in Genres.options(:movies)
  end

  test "an address names a genre only from the list, and discover is asked in the kind's terms" do
    assert Genres.parse("horror") == "horror"
    assert Genres.parse("nonsense") == nil
    assert Genres.parse(nil) == nil
    assert Genres.with_genres("action", :movies) == "28"
    assert Genres.with_genres("action", :anime) == "10759"
  end

  test "a title matches by its own kind's ids, and an unknown list matches nothing" do
    assert Genres.match?("horror", "movie", [27, 53])
    refute Genres.match?("horror", "tv", [27])
    assert Genres.match?("action", "tv", [10759, 18])
    refute Genres.match?("action", "movie", [10759])
    refute Genres.match?("horror", "movie", nil)
  end

  test "genres are kept per title and read back; a title not read yet is not in the answer" do
    Roki.Repo.query!("insert into roki_titles (type, id, name, genres, seen_at) values ('movie', 1, 'A', '{27,53}', now()), ('movie', 2, 'B', null, now())")
    assert Genres.known([{"movie", 1}, {"movie", 2}, {"tv", 3}]) == %{{"movie", 1} => [27, 53]}
    assert Genres.missing_count([{"movie", 1}, {"movie", 2}, {"tv", 3}]) == 2
  end
end
