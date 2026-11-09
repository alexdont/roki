defmodule Roki.RatingBreakdownTest do
  use Roki.DataCase, async: true

  alias Roki.Profile

  @counts %{
    "movie" => %{8.0 => 2, 7.5 => 1},
    "tv" => %{8.0 => 1, 10.0 => 1},
    "mal" => %{6.0 => 3}
  }

  test "nothing rated is no breakdown" do
    assert Profile.rating_breakdown(%{}) == nil
    assert Profile.rating_breakdown(@counts, ["manga"]) == nil
  end

  test "counts, average and bars from the lowest score used up to 10" do
    b = Profile.rating_breakdown(@counts)
    assert b.total == 8
    assert b.average == 7.4
    assert b.top == 6.0
    assert hd(b.bars) == {6.0, 3}
    assert List.last(b.bars) == {10.0, 1}
    assert {7.5, 1} in b.bars and {9.0, 0} in b.bars
  end

  test "one kind on its own, whole points when no half points are given" do
    b = Profile.rating_breakdown(@counts, ["mal"])
    assert b.total == 3 and b.average == 6.0
    assert Enum.map(b.bars, &elem(&1, 0)) == [6.0, 7.0, 8.0, 9.0, 10.0]
  end

  describe "counts" do
    setup do
      {:ok, user} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => "bdseasons@example.com",
          "password" => "a-long-enough-password-123",
          "username" => "bdseasons"
        })

      %{uuid: user.uuid}
    end

    test "a season rated on its own counts with the shows", %{uuid: uuid} do
      Profile.note_rating(uuid, {"tv", 7}, 8.0, local: true)
      Profile.put_season_rating(uuid, 7, 1, 8.0)
      Profile.put_season_rating(uuid, 7, 2, 6.5)

      assert %{"tv" => %{8.0 => 2, 6.5 => 1}} = Profile.rating_counts(uuid)
    end
  end
end
