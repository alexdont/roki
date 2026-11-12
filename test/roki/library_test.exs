defmodule Roki.Watch.LibraryTest do
  use ExUnit.Case, async: false

  alias Roki.Watch

  @uuid "01a163a7-a312-7691-8440-db7feaca900f"

  setup do
    dir = Path.join(System.tmp_dir!(), "roki-library-test-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, dir)
    File.mkdir_p!(Roki.Laev.dir(@uuid))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:roki, :laev_dir, prior),
        else: Application.delete_env(:roki, :laev_dir)

      File.rm_rf(dir)
    end)

    :ok
  end

  defp movie,
    do: %{
      type: "movie",
      id: 603,
      title: "The Matrix",
      year: "1999",
      poster_path: "/m.jpg",
      anime?: false,
      seasons: []
    }

  defp show do
    %{
      type: "tv",
      id: 1396,
      title: "A Show",
      year: "2008",
      poster_path: "/s.jpg",
      anime?: false,
      seasons: [
        %{number: 0, episodes: 3, air_date: "2007-01-01"},
        %{number: 1, episodes: 2, air_date: "2020-01-01"},
        %{number: 2, episodes: 5, air_date: "2999-01-01"}
      ]
    }
  end

  test "a film starts as nothing, and each button marks and unmarks" do
    assert %{saved?: false, held?: false, watched?: false} = Watch.library(@uuid, movie())

    assert Watch.toggle_saved(@uuid, movie()) == :added
    assert Watch.library(@uuid, movie()).saved?
    assert Watch.toggle_saved(@uuid, movie()) == :removed
    refute Watch.library(@uuid, movie()).saved?

    assert Watch.toggle_hold(@uuid, movie()) == :held
    assert Watch.library(@uuid, movie()).held?
    assert Watch.toggle_hold(@uuid, movie()) == :released

    Watch.set_watched(@uuid, movie(), nil, nil, true)
    assert Watch.library(@uuid, movie()).watched?
    Watch.set_watched(@uuid, movie(), nil, nil, false)
    refute Watch.library(@uuid, movie()).watched?
  end

  test "several saved titles come off the list in one go" do
    assert Watch.toggle_saved(@uuid, movie()) == :added
    assert Watch.toggle_saved(@uuid, show()) == :added
    assert Watch.unsave_many(@uuid, [movie(), show()]) == 2
    refute Watch.library(@uuid, movie()).saved?
    refute Watch.library(@uuid, show()).saved?
    assert Watch.unsave_many(@uuid, []) == 0
  end

  test "saving writes the title laev's saved list reads back" do
    Watch.toggle_saved(@uuid, movie())

    assert [
             %{
               "type" => "movie",
               "tmdb_id" => 603,
               "title" => "The Matrix",
               "poster" => "https://image.tmdb.org/t/p/w342/m.jpg"
             }
           ] =
             Roki.Laev.run(@uuid, fn -> Laev.Watchlist.all() end)
  end

  test "a series is completed by its own mark, not by its episodes" do
    refute Watch.library(@uuid, show()).all_watched?

    # every episode that is out marked: caught up, still on the watchlist, not completed
    Watch.set_many_watched(@uuid, show(), [{1, 1}, {1, 2}], true)
    refute Watch.library(@uuid, show()).all_watched?
    refute Enum.any?(Roki.Laev.run(@uuid, &Laev.Position.finished_titles/0), &(&1.type == "tv"))

    # the mark under the poster: the show itself, which is what Completed lists
    Roki.Laev.run(@uuid, fn ->
      Laev.Position.set_watched(
        %{type: "tv", tmdb_id: show().id, season: nil, episode: nil},
        true
      )
    end)

    assert Watch.library(@uuid, show()).all_watched?
    assert Enum.any?(Roki.Laev.run(@uuid, &Laev.Position.finished_titles/0), &(&1.type == "tv"))

    # taking one episode back takes the series out of Completed
    Watch.set_watched(@uuid, show(), 1, 2, false)
    refute Watch.library(@uuid, show()).all_watched?
    refute Enum.any?(Roki.Laev.run(@uuid, &Laev.Position.finished_titles/0), &(&1.type == "tv"))
  end

  test "an anime's hold is its MyAnimeList status: without a login there is none, and no whole-series mark" do
    anime = %{show() | anime?: true}
    lib = Watch.library(@uuid, anime)
    refute lib.hold?
    assert Watch.toggle_hold(@uuid, anime) == :released
    refute Watch.library(@uuid, anime).held?
    refute lib.all_watched?
    # A film or show can always be held.
    assert Watch.library(@uuid, show()).hold?
  end

  describe "completing" do
    defp ago(days), do: Date.utc_today() |> Date.add(-days) |> Date.to_iso8601()

    test "only a show that ended and has been quiet for long completes by itself" do
      refute Watch.settled?(%{status: "Ended", last_air_date: ago(30)})
      refute Watch.settled?(%{status: "Ended", last_air_date: ago(500)})
      refute Watch.settled?(%{status: "Returning Series", last_air_date: ago(3000)})
      refute Watch.settled?(%{status: "Ended", last_air_date: nil})
      assert Watch.settled?(%{status: "Ended", last_air_date: ago(900)})
      assert Watch.settled?(%{status: "Canceled", last_air_date: ago(4000)})
    end

    test "taking Completed back leaves the episodes watched: caught up" do
      Watch.set_many_watched(@uuid, show(), [{1, 1}, {1, 2}], true)
      Watch.set_completed(@uuid, show(), true)
      assert Watch.library(@uuid, show()).all_watched?

      Watch.toggle_completed(@uuid, show(), false, [])
      refute Watch.library(@uuid, show()).all_watched?

      assert Roki.Laev.run(@uuid, fn ->
               Laev.Position.finished?(%{type: "tv", tmdb_id: 1396, season: 1, episode: 2})
             end)
    end
  end
end
