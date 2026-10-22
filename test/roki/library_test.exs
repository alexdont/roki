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

  test "saving writes the title laev's saved list reads back" do
    Watch.toggle_saved(@uuid, movie())

    assert [%{"type" => "movie", "tmdb_id" => 603, "title" => "The Matrix", "poster" => "/m.jpg"}] =
             Roki.Laev.run(@uuid, fn -> Laev.Watchlist.all() end)
  end

  test "a series is all watched when every episode that is out has a mark" do
    refute Watch.library(@uuid, show()).all_watched?

    # season 0 (specials) and a season that has not aired do not count
    Watch.set_many_watched(@uuid, show(), [{1, 1}], true)
    refute Watch.library(@uuid, show()).all_watched?

    Watch.set_many_watched(@uuid, show(), [{1, 2}], true)
    assert Watch.library(@uuid, show()).all_watched?

    Watch.set_watched(@uuid, show(), 1, 2, false)
    refute Watch.library(@uuid, show()).all_watched?
  end

  test "anime has no hold and no whole-series mark: its status lives on MyAnimeList" do
    anime = %{show() | anime?: true}
    Watch.toggle_hold(@uuid, anime)
    refute Watch.library(@uuid, anime).held?
    refute Watch.library(@uuid, anime).all_watched?
  end
end
