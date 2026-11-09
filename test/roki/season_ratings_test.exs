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
end
