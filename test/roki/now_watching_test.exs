defmodule Roki.NowWatchingTest do
  use ExUnit.Case, async: false

  @what %{type: "movie", tmdb_id: 1, title: "Heat", poster: nil, season: nil, episode: nil}

  # Other tests report into the same server (it is one for the node) and every change is
  # broadcast to all, so what is waited for is the list itself, not a message.
  defp mine(uuid), do: Enum.filter(Roki.NowWatching.list(), &(&1.user == uuid))

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("did not happen")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  test "a player that reports is listed, paused stays, and it goes when the page does" do
    uuid = Ecto.UUID.generate()
    page = spawn(fn -> Process.sleep(:infinity) end)

    Roki.NowWatching.report(uuid, page, @what, 125.4, 6000, false)

    assert [%{user: ^uuid, position: 125.4, paused?: false, what: %{title: "Heat"}}] =
             mine(uuid)

    Roki.NowWatching.report(uuid, page, @what, 130.0, 6000, true)
    assert [%{paused?: true, position: 130.0}] = mine(uuid)

    Process.exit(page, :kill)
    eventually(fn -> mine(uuid) == [] end)
  end

  test "every change is told to the open pages" do
    Phoenix.PubSub.subscribe(Roki.PubSub, Roki.NowWatching.topic())
    uuid = Ecto.UUID.generate()
    page = spawn(fn -> Process.sleep(:infinity) end)
    Roki.NowWatching.report(uuid, page, @what, 10, 100, false)
    assert_receive :now_watching, 5000
    Process.exit(page, :kill)
  end
end
