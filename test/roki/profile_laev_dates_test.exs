defmodule Roki.ProfileLaevDatesTest do
  @moduledoc """
  A watch date set on the site reaches laev (0.1.48's claimed dates), so the terminal app and
  laev's own stats have the day too. Not async: it points laev at a directory of its own.
  """
  use Roki.DataCase, async: false

  alias Roki.Profile

  @uuid "0199f7a1-0000-7000-8000-000000000002"

  setup do
    dir = Path.join(System.tmp_dir!(), "roki-laev-dates-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, dir)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:roki, :laev_dir, prior),
        else: Application.delete_env(:roki, :laev_dir)

      File.rm_rf(dir)
    end)

    # A connected account: laev's config in its directory.
    udir = Roki.Laev.dir(@uuid)
    File.mkdir_p!(udir)
    File.write!(Path.join(udir, "config"), "LAEV_SYNC_URL=https://sync.invalid/laev\n")

    {:ok, bin} = Ecto.UUID.dump(@uuid)

    for {type, id, tt, tid, title} <- [
          {"movie", 603, "movie", 603, "The Matrix"},
          {"mal", 5114, "tv", 31911, "Fullmetal Alchemist"}
        ] do
      Roki.Repo.query!(
        "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated) values ($1, $2, $3, $4, $5, $6, $7, now(), true)",
        [bin, type, id, tt, tid, title, type == "mal"]
      )
    end

    :ok
  end

  test "a backdate is a claimed date in laev, a film by its TMDB id and an anime by its MAL id" do
    assert {:ok, 2} = Profile.set_watched_at(@uuid, ["movie:603", "mal:5114"], ~D[2019-06-15])

    {film, anime, all} =
      Roki.Laev.run(@uuid, fn ->
        {Laev.Position.watched_on(%{type: "movie", tmdb_id: 603}),
         Laev.Position.watched_on(%{mal_id: 5114}), Laev.Position.claimed_dates()}
      end)

    assert DateTime.from_unix!(film) |> DateTime.to_date() == ~D[2019-06-15]
    assert DateTime.from_unix!(anime) |> DateTime.to_date() == ~D[2019-06-15]
    assert Map.keys(all) |> Enum.sort() == ["mal-5114", "movie-603"]

    # A title not on the list is not dated anywhere.
    assert {:ok, 0} = Profile.set_watched_at(@uuid, ["movie:999"], ~D[2020-01-01])

    assert Roki.Laev.run(@uuid, fn -> Laev.Position.watched_on(%{type: "movie", tmdb_id: 999}) end) ==
             nil
  end
end
