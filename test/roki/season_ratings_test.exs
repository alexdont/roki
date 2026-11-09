defmodule Roki.SeasonRatingsTest do
  use Roki.DataCase, async: true

  alias Roki.Profile

  setup do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "seasons@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "seasonsuser"
      })

    %{uuid: user.uuid}
  end

  test "a season never rated reads as the show's rating, nothing is copied", %{uuid: uuid} do
    own = Profile.season_ratings(uuid, 100)
    assert own == %{}
    assert Profile.season_rating(own, 1, 7.0) == {:seeded, 7.0}
    assert Profile.season_rating(own, 1, nil) == :none
  end

  test "a season's own rating wins, and taking it back returns to the show's", %{uuid: uuid} do
    assert {:ok, 8.5} = Profile.put_season_rating(uuid, 100, 2, 8.4)
    own = Profile.season_ratings(uuid, 100)
    assert own == %{2 => 8.5}
    assert Profile.season_rating(own, 2, 7.0) == {:own, 8.5}
    assert Profile.season_rating(own, 1, 7.0) == {:seeded, 7.0}

    # Rating again replaces it; another show's seasons are separate.
    assert {:ok, 6.0} = Profile.put_season_rating(uuid, 100, 2, 6)
    assert Profile.season_ratings(uuid, 100) == %{2 => 6.0}
    assert Profile.season_ratings(uuid, 101) == %{}

    assert :ok = Profile.clear_season_rating(uuid, 100, 2)
    assert Profile.season_ratings(uuid, 100) == %{}
  end

  test "the day a season was watched is kept once, and a rating never moves it", %{uuid: uuid} do
    assert :set = Profile.set_season_date_once(uuid, "tv", 100, 1, ~D[2026-03-01])
    # Finishing it again later, or rating it, keeps the first day.
    assert :kept = Profile.set_season_date_once(uuid, "tv", 100, 1, ~D[2026-11-09])
    Profile.put_season_rating(uuid, 100, 1, 9)
    assert %{{"tv", 100, 1} => at} = Profile.season_dates(uuid)
    assert DateTime.from_unix!(at) |> DateTime.to_date() == ~D[2026-03-01]

    # Only the owner's own edit moves it.
    :ok = Profile.set_season_date(uuid, "tv", 100, 1, ~D[2026-04-02])
    assert %{{"tv", 100, 1} => at} = Profile.season_dates(uuid)
    assert DateTime.from_unix!(at) |> DateTime.to_date() == ~D[2026-04-02]
  end

  test "the watched list's notes: each season's day and rating, a season with neither left out",
       %{
         uuid: uuid
       } do
    Profile.set_season_date_once(uuid, "tv", 100, 1, ~D[2026-03-01])
    Profile.put_season_rating(uuid, 100, 1, 8)
    Profile.put_season_rating(uuid, 100, 3, 6.5)
    Profile.set_season_date_once(uuid, "tv", 200, 2, ~D[2026-05-05])

    notes = Profile.season_notes(uuid)

    assert [%{season: 1, score: 8.0, at: at1}, %{season: 3, score: 6.5, at: nil}] =
             notes["tv:100"]

    assert is_integer(at1)
    assert [%{season: 2, score: nil, at: at2}] = notes["tv:200"]
    assert is_integer(at2)
    assert Map.keys(notes) |> Enum.sort() == ["tv:100", "tv:200"]
  end

  describe "by_season" do
    defp show(extra \\ %{}),
      do:
        Map.merge(
          %{
            key: "tv:7",
            type: "tv",
            id: 7,
            mal_id: nil,
            title: "The Paper",
            at: 1_790_000_000,
            dated?: true,
            note: "2/2 seasons"
          },
          extra
        )

    @notes %{
      "tv:7" => [
        %{season: 1, at: 1_757_000_000, score: 8.0},
        %{season: 2, at: 1_788_000_000, score: nil}
      ]
    }

    test "a show watched in two seasons is two listings, each on its own day" do
      list = Profile.by_season([show()], @notes)
      assert [%{season_no: 2, at: 1_788_000_000}, %{season_no: 1, at: 1_757_000_000}] = list
      assert Enum.all?(list, &(&1.key == "tv:7" and &1.dated?))
    end

    test "a season's own rating goes on its listing, the show's rating stands in for the rest" do
      [two, one] = Profile.by_season([show()], @notes)
      assert one.season_score == 8.0 and two.season_score == nil

      ratings = %{{"tv", 7} => 6.5}
      assert [%{score: 8.0}, %{score: 6.5}] = Profile.arrange([one, two], ratings, :all, :oldest)

      # Ratings hidden: no season score is shown.
      [_, one] = Profile.by_season([show()], @notes, false)
      assert one.season_score == false
      assert [%{score: nil}] = Profile.arrange([one], %{}, :all, :latest)
    end

    test "seasons watched beyond the dated ones keep the show's own listing too" do
      list = Profile.by_season([show(%{note: "3/5 seasons"})], @notes)
      assert length(list) == 3
      assert Enum.count(list, &is_nil(&1[:season_no])) == 1
    end

    test "the listings keep the newest-first order, months in sequence" do
      newer = show(%{key: "tv:8", id: 8, title: "Newer", at: 1_792_000_000})
      older = show(%{key: "tv:9", id: 9, title: "Older", at: 1_600_000_000})
      # tv:7's seasons fall on days both before and after the others.
      list = Profile.by_season([newer, show(), older], @notes)
      assert Enum.map(list, & &1.at) == Enum.sort(Enum.map(list, & &1.at), :desc)

      assert Enum.map(list, &{&1.key, &1[:season_no]}) ==
               [{"tv:8", nil}, {"tv:7", 2}, {"tv:7", 1}, {"tv:9", nil}]
    end

    test "films, anime entries and shows with no season day are left alone" do
      film = show(%{key: "movie:1", type: "movie"})
      anime = show(%{key: "mal:5", mal_id: 5})
      plain = show(%{key: "tv:99"})
      assert Profile.by_season([film, anime, plain], @notes) == [film, anime, plain]
    end
  end
end
