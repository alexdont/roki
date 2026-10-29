defmodule RokiWeb.SeasonDateTest do
  @moduledoc """
  Dating one season of a show: what is stored, and what the stats page then counts it under.
  """
  use RokiWeb.ConnCase

  alias Roki.{Profile, Spent}

  setup do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "season@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "seasonuser"
      })

    {:ok, user: user}
  end

  test "a season's date is kept apart from the title's", %{user: user} do
    assert Profile.season_dates(user.uuid) == %{}

    :ok = Profile.set_season_date(user.uuid, "tv", 110_316, 1, ~D[2021-03-04])
    dates = Profile.season_dates(user.uuid)

    assert map_size(dates) == 1

    assert {"tv", 110_316, 1} |> then(&dates[&1]) |> DateTime.from_unix!() |> DateTime.to_date() ==
             ~D[2021-03-04]

    # The title itself is untouched: laev rewrites that table, these answers it does not have.
    assert Profile.watch_dates(user.uuid) == %{}
  end

  test "setting it again moves it, and nil takes it back", %{user: user} do
    :ok = Profile.set_season_date(user.uuid, "tv", 110_316, 1, ~D[2021-03-04])
    :ok = Profile.set_season_date(user.uuid, "tv", 110_316, 1, ~D[2022-06-01])

    [at] = Map.values(Profile.season_dates(user.uuid))
    assert at |> DateTime.from_unix!() |> DateTime.to_date() == ~D[2022-06-01]

    :ok = Profile.set_season_date(user.uuid, "tv", 110_316, 1, nil)
    assert Profile.season_dates(user.uuid) == %{}
  end

  test "the stats page then counts that season under its own date", %{user: user} do
    :ok = Profile.set_season_date(user.uuid, "tv", 110_316, 1, ~D[2021-03-04])

    now = System.os_time(:second)

    stats = %{
      titles: [
        %{
          type: "tv",
          id: 110_316,
          title: "Alice in Borderland",
          seconds: 10_000,
          off: 0,
          anime: false,
          last_seen: now
        }
      ],
      seasons: %{{"tv", 110_316} => %{1 => 8, 2 => 2}}
    }

    entries = Spent.watched(stats, %{}, Profile.season_dates(user.uuid))

    # Season one is its own row, four fifths of the hours, back in 2021.
    s1 = Enum.find(entries, &(&1.title == "Alice in Borderland · S1"))
    assert s1.seconds == 8000
    assert s1.at |> DateTime.from_unix!() |> DateTime.to_date() == ~D[2021-03-04]

    # This week holds only what is left of the show.
    assert Spent.total(Spent.within(entries, 7, now)) == 2000
    # And the show still adds up.
    assert Spent.total(entries) == 10_000
  end
end
