defmodule Roki.ProfileTest do
  use Roki.DataCase, async: true

  alias Roki.Profile

  @uuid "0199f7a1-0000-7000-8000-000000000001"

  test "a profile starts empty and open, and keeps what its owner writes" do
    assert %{public: true, bio: "", banner: nil, show_history: true} = Profile.get(@uuid)

    assert {:ok, p} = Profile.update(@uuid, %{"bio" => "  Films and anime.  "})
    assert %{bio: "Films and anime.", public: true} = p

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
      %{
        type: "movie",
        id: 1,
        mal_id: nil,
        title: "Film",
        anime: false,
        at: 300,
        dated?: true,
        poster: nil
      },
      %{
        type: "tv",
        id: 2,
        mal_id: nil,
        title: "Show",
        anime: false,
        at: 200,
        dated?: true,
        poster: nil
      },
      %{
        type: "tv",
        id: 3,
        mal_id: 5114,
        title: "Anime",
        anime: true,
        at: 100,
        dated?: true,
        poster: nil
      },
      %{
        type: "movie",
        id: 4,
        mal_id: nil,
        title: "Unrated",
        anime: false,
        at: 400,
        dated?: true,
        poster: nil
      }
    ]

    ratings = %{{"movie", 1} => 8.0, {"tv", 2} => 10.0, {"mal", 5114} => 10.0}

    assert Enum.map(Profile.arrange(items, ratings, :all, :latest), & &1.id) == [1, 2, 3, 4]

    assert Enum.map(Profile.arrange(items, ratings, :all, :top), &{&1.id, &1.badge}) == [
             {2, "★ 10"},
             {3, "★ 10"},
             {1, "★ 8"},
             {4, nil}
           ]

    assert Enum.map(Profile.arrange(items, ratings, :anime, :latest), & &1.id) == [3]
    assert Enum.map(Profile.arrange(items, ratings, :movie, :top, true), & &1.id) == []
    assert Enum.map(Profile.arrange(items, ratings, :all, :top, true), & &1.id) == [2, 3]
    assert Enum.map(Profile.arrange(items, ratings, :all, :latest, 8), & &1.id) == [1]
    assert Enum.map(Profile.arrange(items, ratings, :all, :latest, 9), & &1.id) == []
    assert Profile.rating_param("7") == 7
    assert Profile.rating_param("11") == nil
    assert Profile.rating_param(nil) == nil
    assert Profile.score_text(8.5) == "8.5"
  end

  defp watched(uuid, rows) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    for {type, id, tmdb_type, tmdb_id, title, anime} <- rows do
      Roki.Repo.query!(
        "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated) values ($1, $2, $3, $4, $5, $6, $7, now(), true)",
        [bin, type, id, tmdb_type, tmdb_id, title, anime]
      )
    end
  end

  test "a shelf takes only its own kind, as many as fit, and the picker lists the best rated first" do
    watched(@uuid, [
      {"movie", 1, "movie", 1, "Okay Film", false},
      {"movie", 2, "movie", 2, "Great Film", false},
      {"movie", 3, "movie", 3, "Unrated Film", false},
      {"tv", 10, "tv", 10, "Some Show", false},
      {"tv", 20, "tv", 20, "Some Anime", true},
      {"mal", 30, nil, nil, "MAL Only Anime", true}
    ])

    Profile.note_rating(@uuid, {"movie", 1}, 6.0)
    Profile.note_rating(@uuid, {"movie", 2}, 10.0)
    Profile.note_rating(@uuid, {"tv", 10}, 9.0)
    Profile.note_rating(@uuid, {"mal", 30}, 8.0)

    # Each picker has its own kind and nothing else; best rated first, the unrated last.
    assert Enum.map(Profile.picker(@uuid, :movie), &{&1.title, &1.key}) ==
             [{"Great Film", "movie:2"}, {"Okay Film", "movie:1"}, {"Unrated Film", "movie:3"}]

    assert Enum.map(Profile.picker(@uuid, :tv), & &1.key) == ["tv:10"]
    assert Enum.map(Profile.picker(@uuid, :anime), & &1.key) == ["mal:30", "tv:20"]
    assert Profile.picker(@uuid, :manga) == []

    # A film cannot go on the shows shelf, nor a show on the films shelf, however it is asked.
    assert {:error, msg} = Profile.add_favorites(@uuid, :tv, ["movie:1"])
    assert msg =~ "None of those"
    assert {:error, _} = Profile.add_favorites(@uuid, :movie, ["tv:10", "nonsense", "movie:999"])
    assert {:error, _} = Profile.add_favorites(@uuid, :manga, ["movie:1"])

    # Several at once; the stray one in the list is left out.
    assert {:ok, favs, 2} = Profile.add_favorites(@uuid, :movie, ["movie:2", "tv:10", "movie:1"])
    assert Enum.map(favs.movie, &{&1.id, &1.position}) == [{2, 1}, {1, 2}]
    assert favs.tv == []

    # What is on the shelf is marked in the picker, and cannot be added twice.
    assert Enum.find(Profile.picker(@uuid, :movie), &(&1.key == "movie:2")).on_shelf
    assert {:error, _} = Profile.add_favorites(@uuid, :movie, ["movie:2"])

    # Drag order: the shelf as it was dropped; anything but exactly its titles is refused.
    assert {:ok, favs} = Profile.reorder_favorites(@uuid, :movie, ["movie:1", "movie:2"])
    assert Enum.map(favs.movie, & &1.id) == [1, 2]
    assert {:error, same} = Profile.reorder_favorites(@uuid, :movie, ["movie:1"])
    assert Enum.map(same.movie, & &1.id) == [1, 2]
    assert {:error, _} = Profile.reorder_favorites(@uuid, :movie, ["movie:1", "movie:3"])

    # The shelf only has ten places.
    for n <- 100..110, do: watched(@uuid, [{"movie", n, "movie", n, "Film #{n}", false}])
    keys = for n <- 100..110, do: "movie:#{n}"
    assert {:ok, favs, 8} = Profile.add_favorites(@uuid, :movie, keys)
    assert length(favs.movie) == 10
    assert {:error, msg} = Profile.add_favorites(@uuid, :movie, ["movie:3"])
    assert msg =~ "holds 10"
  end

  test "a pull's news is the film or episode newly finished, never a backlog" do
    before = MapSet.new(["movie-1", "tv-5-s1e1"])

    assert Roki.Laev.news(before, MapSet.new(["movie-1", "tv-5-s1e1", "movie-1561726"])) == [
             {"movie", 1_561_726, nil, nil}
           ]

    assert Roki.Laev.news(before, MapSet.put(before, "tv-5-s1e2")) == [{"tv", 5, 1, 2}]
    # A whole show or an anime entry is not one thing watched.
    assert Roki.Laev.news(before, MapSet.new(["movie-1", "tv-5-s1e1", "tv-9", "mal-30-e1"])) == []
    # A first sync, and an import.
    assert Roki.Laev.news(MapSet.new(), MapSet.new(["movie-1", "movie-2"])) == []

    assert Roki.Laev.news(
             before,
             MapSet.union(before, MapSet.new(for n <- 100..110, do: "movie-#{n}"))
           ) == []

    assert Roki.Laev.news(before, before) == []
  end

  test "a backdated watch date puts a title back in the history, and stays through a rebuild" do
    watched(@uuid, [
      {"movie", 1, "movie", 1, "Seen Last Week", false},
      {"movie", 2, "movie", 2, "Found Years Later", false},
      {"tv", 3, "tv", 3, "Another Old One", false}
    ])

    # Marked just now, all three: the order is the order of marking.
    assert {:ok, 2} =
             Profile.set_watched_at(@uuid, ["movie:2", "tv:3", "movie:999"], ~D[2019-06-15])

    items = Profile.history(@uuid)

    # The newest is the one never backdated; the two old ones are in 2019, in the order given.
    assert Enum.map(items, & &1.title) == [
             "Seen Last Week",
             "Found Years Later",
             "Another Old One"
           ]

    assert Enum.map(items, &DateTime.from_unix!(&1.at).year) |> Enum.take(-2) == [2019, 2019]
    assert hd(items).key == "movie:1"

    # A later rebuild from laev's marks stamps everything today again; the dates are laid back.
    {:ok, bin} = Ecto.UUID.dump(@uuid)
    Roki.Repo.query!("update roki_watched set at = now() where user_uuid = $1", [bin])
    assert :ok = Profile.reapply_dates(@uuid)

    assert Enum.map(Profile.history(@uuid), & &1.title) == [
             "Seen Last Week",
             "Found Years Later",
             "Another Old One"
           ]

    # Putting one of the old ones on a later day moves just it.
    assert {:ok, 1} = Profile.set_watched_at(@uuid, ["movie:2"], ~D[2022-01-01])

    assert Enum.map(Profile.history(@uuid), & &1.title) == [
             "Seen Last Week",
             "Found Years Later",
             "Another Old One"
           ]

    assert DateTime.from_unix!(Enum.at(Profile.history(@uuid), 1).at).year == 2022

    # Taking one off the list takes its date with it.
    assert {:ok, 1} = Profile.remove_watched(@uuid, ["movie:2"])
    assert Enum.map(Profile.history(@uuid), & &1.key) == ["movie:1", "tv:3"]

    assert Roki.Repo.query!(
             "select count(*) from roki_watch_dates where user_uuid = $1 and id = 2",
             [bin]
           ).rows == [[0]]
  end

  test "a show watched a season or two and not finished takes the date of the latest season dated" do
    {:ok, bin} = Ecto.UUID.dump(@uuid)

    for {id, title} <- [{3, "Half Watched"}, {4, "Never Dated"}] do
      Roki.Repo.query!(
        "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated, status) values ($1, 'tv', $2, 'tv', $2, $3, false, to_timestamp(0), false, 'progress')",
        [bin, id, title]
      )
    end

    :ok = Profile.set_season_date(@uuid, "tv", 3, 1, ~D[2019-01-16])
    :ok = Profile.set_season_date(@uuid, "tv", 3, 2, ~D[2020-03-02])

    items = Map.new(Profile.history_all(@uuid), &{&1.title, &1})

    assert %{dated?: true, at: at} = items["Half Watched"]
    assert DateTime.from_unix!(at) |> DateTime.to_date() == ~D[2020-03-02]
    assert %{dated?: false} = items["Never Dated"]
  end

  test "a profile's counts follow the finished titles" do
    watched(@uuid, [
      {"movie", 1, "movie", 1, "Film", false},
      {"movie", 2, "movie", 2, "Other Film", false},
      {"tv", 10, "tv", 10, "Show", false},
      {"mal", 30, nil, nil, "MAL Anime", true}
    ])

    assert %{watched: 4, films: 2} = Profile.counts(@uuid)
  end

  test "a shelf shows numbers only once its owner turns them on" do
    refute Profile.ranked?(Profile.get(@uuid), :movie)
    assert {:ok, p} = Profile.set_ranked(@uuid, :movie, true)
    assert Profile.ranked?(p, :movie)
    refute Profile.ranked?(p, :tv)
    assert {:ok, _} = Profile.set_ranked(@uuid, :tv, true)
    assert {:ok, p} = Profile.set_ranked(@uuid, :movie, false)
    refute Profile.ranked?(p, :movie)
    assert Profile.ranked?(p, :tv)
  end

  test "a banner is a media file; anything else named there is no banner" do
    assert Profile.banner_url(%{banner: "0199f7a1-0000-7000-8000-000000000002"}) =~
             ~r{/file/0199f7a1-0000-7000-8000-000000000002/original/}

    assert Profile.banner_url(%{banner: "a-1.jpg"}) == nil
    assert Profile.banner_url(%{banner: nil}) == nil
  end

  describe "dating titles that appear on the list" do
    defp finished(id),
      do: %{type: "movie", id: id, title: "Film #{id}", at: 0, dated?: false, status: "finished"}

    defp dated_count do
      {:ok, bin} = Ecto.UUID.dump(@uuid)
      Roki.Repo.query!("select count(*) from roki_watch_dates where user_uuid = $1", [bin]).rows
    end

    test "a few new finished titles are dated now, a whole catalogue arriving is not" do
      Profile.replace_watched(@uuid, [finished(1)])
      # The first copy of an account is left alone.
      assert dated_count() == [[0]]

      Profile.replace_watched(@uuid, Enum.map(1..4, &finished/1))
      assert dated_count() == [[3]]

      # Hundreds at once is an import: undated, not filed under today.
      Profile.replace_watched(@uuid, Enum.map(1..300, &finished/1))
      assert dated_count() == [[3]]
      assert Enum.count(Profile.history(@uuid), &(&1.at <= 0 or not &1.dated?)) == 297
    end
  end
end
