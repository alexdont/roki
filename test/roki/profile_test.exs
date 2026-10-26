defmodule Roki.ProfileTest do
  use Roki.DataCase, async: true

  alias Roki.Profile

  @uuid "0199f7a1-0000-7000-8000-000000000001"

  test "a profile starts private and empty, and keeps what its owner writes" do
    assert %{public: false, bio: "", banner: nil, show_history: true} = Profile.get(@uuid)

    assert {:ok, p} = Profile.update(@uuid, %{"bio" => "  Films and anime.  ", "public" => "true", "show_ratings" => "false"})
    assert %{bio: "Films and anime.", public: true, show_history: true, show_ratings: false} = p
    assert Profile.get(@uuid).public

    assert {:error, msg} = Profile.update(@uuid, %{"bio" => String.duplicate("x", 601)})
    assert msg =~ "600"
  end

  test "ratings made on the site are noted at once, and taken back" do
    Profile.note_rating(@uuid, {"movie", 10331}, 9.5)
    Profile.note_rating(@uuid, {"mal", 5114}, 10)
    assert Profile.ratings(@uuid) == %{{"movie", 10331} => 9.5, {"mal", 5114} => 10.0}

    Profile.note_rating(@uuid, {"movie", 10331}, nil)
    assert Profile.ratings(@uuid) == %{{"mal", 5114} => 10.0}
  end

  test "the history is arranged by kind, by rating, and down to the tens" do
    items = [
      %{type: "movie", id: 1, mal_id: nil, title: "Film", anime: false, at: 300, dated?: true, poster: nil},
      %{type: "tv", id: 2, mal_id: nil, title: "Show", anime: false, at: 200, dated?: true, poster: nil},
      %{type: "tv", id: 3, mal_id: 5114, title: "Anime", anime: true, at: 100, dated?: true, poster: nil},
      %{type: "movie", id: 4, mal_id: nil, title: "Unrated", anime: false, at: 400, dated?: true, poster: nil}
    ]

    ratings = %{{"movie", 1} => 8.0, {"tv", 2} => 10.0, {"mal", 5114} => 10.0}

    assert Enum.map(Profile.arrange(items, ratings, :all, :latest), & &1.id) == [1, 2, 3, 4]
    assert Enum.map(Profile.arrange(items, ratings, :all, :top), &{&1.id, &1.badge}) == [{2, "★ 10"}, {3, "★ 10"}, {1, "★ 8"}, {4, nil}]
    assert Enum.map(Profile.arrange(items, ratings, :anime, :latest), & &1.id) == [3]
    assert Enum.map(Profile.arrange(items, ratings, :movie, :top, true), & &1.id) == []
    assert Enum.map(Profile.arrange(items, ratings, :all, :top, true), & &1.id) == [2, 3]
    assert Profile.score_text(8.5) == "8.5"
  end

  test "banner names are the site's own, nothing else is served" do
    assert Profile.banner_file("0199f7a1-0000-7000-8000-000000000001-1700000000.jpg") =~ ~r{/roki-banners/0199f7a1}
    assert Profile.banner_file("../etc/passwd") == nil
    assert Profile.banner_file("x.jpg") == nil
    assert Profile.banner_url(%{banner: "a-1.jpg"}) == "/banners/a-1.jpg"
    assert Profile.banner_url(%{banner: nil}) == nil
  end
end
