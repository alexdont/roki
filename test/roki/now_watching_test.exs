defmodule Roki.NowWatchingTest do
  use ExUnit.Case, async: false

  @what %{type: "movie", tmdb_id: 1, title: "Heat", poster: nil, season: nil, episode: nil}

  setup do
    Phoenix.PubSub.subscribe(Roki.PubSub, Roki.NowWatching.topic())
    :ok
  end

  test "a player that reports is listed, paused stays, and it goes when the page does" do
    uuid = Ecto.UUID.generate()
    page = spawn(fn -> Process.sleep(:infinity) end)

    Roki.NowWatching.report(uuid, page, @what, 125.4, 6000, false)
    assert_receive :now_watching

    assert [%{user: ^uuid, position: 125.4, paused?: false, what: %{title: "Heat"}}] =
             Enum.filter(Roki.NowWatching.list(), &(&1.user == uuid))

    Roki.NowWatching.report(uuid, page, @what, 130.0, 6000, true)
    assert_receive :now_watching
    assert [%{paused?: true}] = Enum.filter(Roki.NowWatching.list(), &(&1.user == uuid))

    Process.exit(page, :kill)
    assert_receive :now_watching
    assert Enum.filter(Roki.NowWatching.list(), &(&1.user == uuid)) == []
  end
end
